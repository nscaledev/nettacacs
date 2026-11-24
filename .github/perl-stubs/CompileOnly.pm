package CompileOnly;

# Compile-only stand-ins for optional CPAN modules and the Scm XS module.
# They let perl -c parse every line without requiring network installs or a
# project build. Production code never adds this directory to @INC.

use strict;
use warnings;

BEGIN {
	for my $module (qw(
		Authen/OPIE.pm
		Crypt/Cipher/AES.pm
		Net/Frame/Layer/IPv4.pm
		Net/Frame/Layer/IPv6.pm
		Net/Frame/Layer/UDP.pm
		Net/Frame/Simple.pm
		Net/RawIP.pm
		Net/TacacsPlus/Client.pm
		Net/TacacsPlus/Constants.pm
		Net/TacacsPlus/Packet.pm
		Net/Write/Layer.pm
		Net/Write/Layer3.pm
		Scm.pm
	)) {
		$INC{$module} = __FILE__;
	}
}

sub export_requested {
	my ($caller, @symbols) = @_;
	no strict 'refs';
	for my $symbol (@symbols) {
		next unless $symbol =~ /^[A-Za-z_][A-Za-z0-9_]*$/;
		*{"${caller}::$symbol"} = sub { 0 };
	}
}

package Authen::OPIE;
sub import { shift; CompileOnly::export_requested(scalar caller, @_); }

package Crypt::Cipher::AES;
sub import { }

package Net::Frame::Layer::IPv4;
sub import {
	no strict 'refs';
	*{(caller) . '::NF_IPv4_PROTOCOL_UDP'} = sub () { 0 };
}

package Net::Frame::Layer::IPv6;
sub import {
	no strict 'refs';
	*{(caller) . '::NF_IPv6_PROTOCOL_UDP'} = sub () { 0 };
}

package Net::Frame::Layer::UDP;
sub import { }

package Net::Frame::Simple;
sub import { }

package Net::RawIP;
sub import { }

package Net::TacacsPlus::Client;
sub import { }

package Net::TacacsPlus::Constants;
sub import { }

package Net::TacacsPlus::Packet;
sub import { }

package Net::Write::Layer;
sub import {
	no strict 'refs';
	*{(caller) . '::NW_AF_INET6'} = sub () { 0 };
}

package Net::Write::Layer3;
sub import { }

package Scm;
sub import { }
sub SCM_DONE () { 0 }
sub SCM_KEEPALIVE () { 1 }
sub SCM_MAX () { 5 }
sub SCM_ACCEPT () { 6 }

1;
