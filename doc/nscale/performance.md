# tac_plus-ng memory exhaustion: findings and plan

Ticket: NETDEV-2. Status: investigation, no code changed yet.

## Summary

A production TACACS+ server with 16 GB of RAM ran out of memory. The kernel
killed a `perl` process that held 6.9 GB, and the host spent its time swapping.
The trigger was a monitoring service account that logged in to the network
devices about 2,300 times per hour. That is less than one login per second, so
the load itself is small. The server design should absorb it easily.

Three things are established:

1. **Nothing limits the number of Perl processes to what the host can hold.**
   With our settings the daemon may start up to 640 Perl back-end processes.
   Each one measured 15 to 22 MB, so the worst case is 10 to 14 GB.
2. **Nothing limits how long a request waits.** A Perl process that waits for
   the LDAP server waits for ever, and the queue behind it has no maximum
   length.
3. **Three settings in our configuration do the opposite of what we intend.**
   The Perl script treats a variable set to `0` as switched on. So StartTLS and
   nested group expansion are both active, and every request opens a new LDAP
   connection.

One thing is **not** explained: how a single Perl process reached 6.9 GB. The
script did not grow in any local test (see [What was tested](#what-was-tested)).
The tests ran on macOS, not in the production container image, so this result
does not clear the production build. Step 1 of the plan closes that gap.

## What happened

```
Out of memory: Killed process 125705 (perl) total-vm:7176580kB,
  anon-rss:6968744kB, file-rss:256kB, shmem-rss:0kB, UID:0
```

At the time `top` showed load average 47, 99% system CPU, `kswapd0` at 81% CPU,
300 MB available, and all 2 GB of swap in use. Adding swap delayed the failure
but did not prevent it: memory use kept growing until the swap was full too.
Reducing the polling rate of the service account made the host stable.

The high system CPU and the busy `systemd` and `systemd-journald` processes are
effects of the memory shortage (page reclaim), not a second problem.

## How the processes are arranged

```
spawnd (1 process)
  └─ tac_plus-ng worker           1 to 32   ("instances max" in our config)
       └─ MAVIS "external" module
            └─ perl mavis_tacplus_ldap.pl     4 to 20 per worker (code default)
                 └─ one LDAP connection per request
```

- `spawnd` accepts the TCP connections and starts more workers as the number of
  open connections rises.
- Each worker has its own set of Perl children. Children are started with
  `fork` and `exec`, so they share no memory with each other.
- Each worker also has its own cache of MAVIS answers. A login that worker A
  has cached is a new LDAP lookup for worker B.

## Findings

### 1. The process limits allow 640 Perl processes

The `external` module starts 4 children per worker at start-up and up to 20 on
demand ([libmavis_external.c:991](../../mavis/libmavis_external.c#L991)). Our
configuration sets neither value, and allows 32 workers.

| | Workers | Perl per worker | Perl total | Memory at 15 to 22 MB each |
|---|---|---|---|---|
| Idle, at start | 1 | 4 | 4 | under 0.1 GB |
| Worst case | 32 | 20 | 640 | 9.6 to 14.1 GB |

The 15 to 22 MB is the resident size measured locally (22 MB when the TLS
libraries are loaded). It has not been measured in the production image.

A child is only started when all existing children of that worker are busy
([libmavis_external.c:873-881](../../mavis/libmavis_external.c#L873-L881)). So
the count stays low while LDAP answers quickly, and climbs to the maximum when
LDAP is slow. A child that was started is never stopped while the worker lives.

For comparison: against a local test server one child completed a request in
about 40 ms, including a new connection and a TLS handshake. That is about 25
requests per second for one child. The load in the incident was under 1 login
per second.

### 2. A slow LDAP server blocks children for ever, and the queue has no limit

- The Perl script passes its timeout only to the TCP connect
  ([mavis_tacplus_ldap.pl:417](../../mavis/perl/mavis_tacplus_ldap.pl#L417)).
  Reads have no timeout. In a test where the LDAP server accepted the search
  and never answered, the child was still blocked when the test stopped it
  after 20 seconds.
- When all children are busy, the worker puts new requests in a queue
  ([libmavis_external.c:843-871](../../mavis/libmavis_external.c#L843-L871)).
  The queue has no maximum length and its entries have no age limit.
- If the client gives up, the worker marks the request as cancelled, but the
  child keeps working on it.

Together with finding 1 this gives a failure that feeds itself: LDAP slows down,
children block, devices retry, connections accumulate, `spawnd` starts workers,
and each worker starts its own children.

This sequence is derived from the code. It was not observed on the host,
because no per-process data was captured during the incident.

### 3. Settings that are set to `0` are switched on

The script tests most of its switches with `defined`, so the value does not
matter. Our configuration writes these variables with the value `0` to mean
"off".

| Variable as rendered | Intended | Actual | Code |
|---|---|---|---|
| `USE_TLS = "0"` | plain LDAP | StartTLS on every connection | [line 422](../../mavis/perl/mavis_tacplus_ldap.pl#L422) |
| `EXPAND_AD_GROUP_MEMBERSHIP = "0"` | direct groups only | nested groups are resolved, one LDAP search per group | [line 598](../../mavis/perl/mavis_tacplus_ldap.pl#L598) |
| `REQUIRE_TACACS_GROUP_PREFIX = "0"` | no requirement | a user without a matching group is rejected | [line 620](../../mavis/perl/mavis_tacplus_ldap.pl#L620) |

Both of the first two were confirmed by test. With `USE_TLS=0` and a server
that refuses StartTLS, every request failed with "TLS negotiation failed". With
`EXPAND_AD_GROUP_MEMBERSHIP=0`, the answer contained the parent groups.

Logins work in production, so the directory server must accept StartTLS. That
is good for the bind password, but it was not a decision anyone made, and the
certificate is not checked.

In addition `FLAG_CACHE_CONNECTION` is not set, so the script closes the LDAP
connection after every request
([line 662](../../mavis/perl/mavis_tacplus_ldap.pl#L662)). Each request
therefore costs a TCP connect, a TLS handshake, two binds and at least two
searches, plus one search per group.

### 4. The answer cache works per worker

`tac_plus-ng` keeps a MAVIS answer for 120 seconds by default
([config.c:690](../../tac_plus-ng/config.c#L690)), and each worker has its own
cache. A service account that logs in to many devices lands on many workers, so
the same account is looked up again and again. Fewer workers and a longer cache
time both reduce the number of LDAP requests directly.

This is from reading the code. The cache hit rate was not measured.

### 5. Nothing protects the host from the container

The deployment sets no memory limit and no process limit on the container. So a
process that grows takes memory from the whole host, including `journald` and
`systemd`, until the kernel picks a victim. With a limit, the kernel would stop
the container early and the restart policy would bring it back in seconds.

### 6. The single 6.9 GB process is not explained

640 processes of 20 MB explain a full host. They do not explain one process of
6.9 GB. Something made a single Perl process grow.

The script was run for 2,000 to 3,000 requests in each case below, and its
resident size stayed flat every time. So a plain leak per request in the script
is unlikely on the tested platform. The production image differs in ways that
matter (Alpine with musl, OpenSSL 3, other versions of Perl and `Net::LDAP`),
and it was not tested, because no container runtime was available.

Still open, in the order they should be tested:

1. **TLS setup per request in the production image.** Each request builds a new
   TLS context. If that context is not released completely on Alpine, the
   growth would be proportional to the request count, as observed.
2. **A very large or damaged LDAP answer.** `Net::LDAP` reads a whole answer
   into memory and the script sets no size limit on its searches.
3. **A different process.** The kernel line says `perl` with UID 0. It is
   assumed to be the MAVIS script, but the command line was not captured.

### 7. Production builds an old commit

The container image builds commit `6f68c33`, which is 605 commits behind
`master` of this fork. The Perl script is almost unchanged since then, so an
update alone will not fix findings 1 to 5. The newer commits do contain fixes in
this area, among them `f943442` (memory safety and denial of service),
`bc03806` (a request lost after an out-of-sync answer), `2a75d83` (a MAVIS
answer that was never freed) and `f9e7485` (a limit for the log buffer).

## What was tested

Method: a small fake LDAP server and a driver that feeds requests to the script
over a pipe, as the daemon does, and reads the resident size with `ps`. Both are
in the [appendix](#appendix-test-harness). Platform: macOS, Perl 5.34,
`Net::LDAP` 0.66.

| Case | Script | Requests | Resident size, start to end |
|---|---|---|---|
| Plain LDAP, 5 groups | `mavis_tacplus_ldap.pl` | 2,000 | 15.2 to 15.2 MB |
| Production variables, server refuses StartTLS | `mavis_tacplus_ldap.pl` | 2,000 | 19.9 to 19.9 MB (all requests fail) |
| Production variables, StartTLS works | `mavis_tacplus_ldap.pl` | 3,000 | 21.5 to 21.8 MB |
| Nested groups, 5 groups with 3 parents each | `mavis_tacplus_ldap.pl` | 2,000 | 15.3 to 15.3 MB |
| Group lookup returns an error | `mavis_tacplus_ldap.pl` | 3,000 | 15.3 to 15.3 MB |
| Plain LDAP | `mavis_tacplus-ng_ldap.pl` | 2,000 | 21.3 to 21.3 MB |
| LDAP server never answers | `mavis_tacplus_ldap.pl` | 1 | blocked until stopped at 20 s |

Not tested: the production container image, the C side of the daemon under
load, the queue growth of finding 2, and the cache behaviour of finding 4.

## Plan

### Step 0: contain it (deployment configuration, no code)

These changes are in the deployment repository, not in this one. The numbers
are starting values to adjust after step 1.

| Change | Why |
|---|---|
| Set `childs min = 1` and `childs max = 4` in the MAVIS module | Limits Perl per worker (finding 1) |
| Lower `instances max` from 32 to about 4 | Limits workers, and improves the cache hit rate (findings 1, 4) |
| Set a memory limit and a process limit on the container | The container is restarted before the host starves (finding 5) |
| Raise `mavis cache timeout` (for example to 600 s) | Fewer LDAP requests for accounts that log in often (finding 4) |
| Do not write a switch variable when it is off | `0` no longer means "on" (finding 3) |
| Decide on StartTLS and nested groups, then set them on purpose | Today both are on by accident (finding 3) |
| Set `FLAG_CACHE_CONNECTION = 1` | One LDAP connection per child, not per request (finding 3) |

With 4 workers and 4 children each, the worst case is 16 Perl processes, about
0.4 GB.

### Step 1: measure in the production image

1. Run the harness from the appendix inside the production container image,
   with the production variables and StartTLS, for at least 100,000 requests.
   This confirms or removes the first open point of finding 6.
2. Capture what was missing this time. Add to the runbook: on a memory alert,
   save `ps -eo pid,ppid,rss,etime,args --sort=-rss` and the container log
   before restarting.
3. Record the number of Perl processes and the largest resident size as
   metrics, and alert on both.
4. Find out how to make the daemon write its `STAT` lines on a schedule. The
   `external` module already counts requests, forks and the longest queue per
   child, and writes them when it receives a statistics request
   ([libmavis_external.c:815-842](../../mavis/libmavis_external.c#L815-L842)).
   What triggers that request was not traced.

### Step 2: fix it in this fork

In order of value:

1. **Limit the queue and the waiting time** in `libmavis_external.c`: a maximum
   queue length, and an answer of "error" for a request that waited longer than
   the session timeout. Stops the feedback of finding 2.
2. **Recycle children**: stop a child after a set number of requests or above a
   set resident size, and start a new one. This bounds the damage of any leak,
   known or not (finding 6).
3. **Stop idle children** after a period without requests, down to
   `childs min`.
4. **Timeouts in the Perl script** for every LDAP operation, and switches that
   treat `0` as off (findings 2, 3).
5. **Evaluate `ldapmavis-mt`**, the LDAP back end written in C that is already
   in this repository. It is one process with threads and has `LDAP_TIMEOUT`,
   `LDAP_NETWORK_TIMEOUT` and `LDAP_SIZELIMIT`. It would remove Perl from the
   request path. It reads a partly different set of variables, so it needs its
   own test against our directory.
6. **Move production to a current commit** of this fork, with the test suite as
   the gate (finding 7).

Each item needs a test in `tac_plus-ng/tests`. The suite already starts a real
`slapd` for the LDAP back ends.

### Step 3: decisions to record as ADRs

- Which LDAP back end we run: the old Perl script, the newer Perl script, or
  `ldapmavis-mt`.
- The limits for workers, children, and container memory, and how they are
  derived from the host size.
- Whether LDAP uses StartTLS or LDAPS, and whether the certificate is checked.
- How far this fork may differ from upstream, and which fixes we send upstream.

## Appendix: test harness

Run the server, then the driver. The script needs `Mavis.pm` on its include
path.

```sh
FAKE_PORT=3899 perl fakeldap.pl &
LDAP_HOSTS=ldap://127.0.0.1:3899 LDAP_BASE=dc=example,dc=com \
LDAP_USER=cn=x LDAP_PASSWD=y LDAP_SERVER_TYPE=microsoft \
  perl drive.pl 100000 5000 perl -I mavis/perl mavis/perl/mavis_tacplus_ldap.pl
```

<details>
<summary>fakeldap.pl</summary>

```perl
#!/usr/bin/env perl
# Minimal fake LDAP server for memory tests of the MAVIS Perl back ends.
# FAKE_GROUPS: groups per user. FAKE_NEST: parents per group.
# FAKE_STARTTLS_RC=0 with FAKE_CERT and FAKE_KEY: accept StartTLS.
# FAKE_GROUP_ERR=<code>: fail group lookups. FAKE_STALL=1: never answer.
use strict; use warnings;
use IO::Socket::INET; use Convert::ASN1 qw(asn_read);
use Net::LDAP::ASN qw(LDAPRequest LDAPResponse);
$SIG{CHLD} = 'IGNORE';
my $port   = $ENV{FAKE_PORT}   || 3899;
my $groups = $ENV{FAKE_GROUPS} // 5;
my $nest   = $ENV{FAKE_NEST}   // 0;
my $tls_rc = $ENV{FAKE_STARTTLS_RC} // 2;
my $suffix = 'OU=groups,DC=example,DC=com';
my $l = IO::Socket::INET->new(Listen => 128, LocalAddr => '127.0.0.1',
    LocalPort => $port, ReuseAddr => 1) or die $!;
sub done {
    my ($s, $id, $op, $rc, $msg) = @_;
    print $s $LDAPResponse->encode(messageID => $id, protocolOp =>
        {$op => {resultCode => $rc, matchedDN => '', errorMessage => $msg // ''}});
}
while (my $s = $l->accept) {
    next if fork;
    close $l; $s->autoflush(1);
    while (asn_read($s, my $pdu)) {
        my $r = $LDAPRequest->decode($pdu) or last;
        my $id = $r->{messageID};
        if ($r->{bindRequest}) { done($s, $id, 'bindResponse', 0) }
        elsif ($r->{unbindRequest}) { last }
        elsif ($r->{extendedReq}) {
            done($s, $id, 'extendedResp', $tls_rc, 'no tls');
            if (!$tls_rc) {
                require IO::Socket::SSL;
                IO::Socket::SSL->start_SSL($s, SSL_server => 1,
                    SSL_cert_file => $ENV{FAKE_CERT}, SSL_key_file => $ENV{FAKE_KEY}) or last;
            }
        }
        elsif (my $q = $r->{searchRequest}) {
            my $base = $q->{baseObject}; my @attrs;
            if ($ENV{FAKE_GROUP_ERR} && $q->{scope} == 0 && $base =~ /^CN=group/i) {
                done($s, $id, 'searchResDone', $ENV{FAKE_GROUP_ERR}, 'err'); next;
            }
            sleep 3600 if $ENV{FAKE_STALL} && $q->{scope} != 0;
            if ($q->{scope} == 0 && $base =~ /^CN=user/i) {
                @attrs = ({type => 'memberOf', vals => [map {"CN=group$_,$suffix"} 1..$groups]});
            } elsif ($q->{scope} == 0 && $base =~ /^CN=group(\d+),/i && $nest) {
                @attrs = ({type => 'memberOf', vals => [map {"CN=parent$1x$_,$suffix"} 1..$nest]});
            } elsif ($q->{scope} != 0) {
                $base = 'CN=user,OU=users,DC=example,DC=com';
            }
            print $s $LDAPResponse->encode(messageID => $id, protocolOp =>
                {searchResEntry => {objectName => $base, attributes => \@attrs}});
            done($s, $id, 'searchResDone', 0);
        }
    }
    exit 0;
}
```

</details>

<details>
<summary>drive.pl</summary>

```perl
#!/usr/bin/env perl
# Feed N MAVIS requests to a back-end script and print its resident size.
# usage: drive.pl <requests> <sample-every> <command...>
use strict; use warnings; use IPC::Open2;
my ($n, $every, @cmd) = @ARGV;
my $pid = open2(my $out, my $in, @cmd);
sub rss { my $r = `ps -o rss= -p $pid`; $r =~ s/\s//g; $r }
my $last = '';
for my $i (1..$n) {
    print $in "0 TACPLUS\n4 testuser\n8 secret\n49 AUTH\n21 serial$i\n=\n";
    my $ans = '';
    while (my $line = <$out>) { $ans .= $line; last if $line =~ /^=\d+$/ }
    $last = $ans;
    printf "%7d requests  rss %8d KB\n", $i, rss() if $i == 1 || $i % $every == 0;
}
$last =~ s/\n/ | /g;
print "last answer: $last\n";
close $in; waitpid $pid, 0;
```

</details>
