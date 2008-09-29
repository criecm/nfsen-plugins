#!/usr/bin/perl
#
#  vim: set ts=3 sw=3:
#
#	Copyright (c) 2007, SURFnet B.V. 
#	All rights reserved.
#
#	Redistribution and use in source and binary forms, with or without modification, 
#	are permitted provided that the following conditions are met:
#
#	*	Redistributions of source code must retain the above copyright notice, this
#		list of conditions and the following disclaimer.
#	*	Redistributions in binary form must reproduce the above copyright notice, this
#		list of conditions and the	following disclaimer in the documentation and/or
#		other materials provided with the distribution.
#	*	Neither the name of the SURFnet B.V. nor the names of its contributors may be
#		used to endorse or promote products derived from this software without specific 
#		prior written permission.
#
#	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY 
#	EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES 
#	OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT 
#	SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
#	INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
#	TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR 
#	BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON	ANY THEORY OF LIABILITY, WHETHER IN 
#	CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
#	ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH 
#	DAMAGE.
#
#  $Author$
#
#  $Id$
#
#  $LastChangedRevision$
#
#

package Botnets;

use Switch;
use strict;
use Time::Local;
use Date::Parse;

use Events qw(process_event);

use Sys::Syslog;
Sys::Syslog::setlogsock('unix');

our $VERSION = 130;

sub _ERROR {
	syslog('err', __PACKAGE__.": ".shift);
}

sub _DEBUG {
	syslog('debug', __PACKAGE__.": ".shift);
}


sub trim
{
	my $string = shift;
	$string =~ s/^\s+//;
	$string =~ s/\s+$//;
	return $string;
}

sub parseLine {
	my ($Out) = @_;

	my ($SrcIp, $Proto, $DstIp, $DstPort, $Flows) = (split (',\s*',$Out));
	
	$Proto=trim(lc($Proto));
	$DstPort=trim($DstPort);
	$Flows=trim($Flows);
	$SrcIp=trim($SrcIp);
	return ($SrcIp, $Proto, $DstIp, $DstPort, $Flows);
}

sub alert_condition { 
	my ($opts) = @_;

#	my ($Year, $Month, $Day, $Hour, $Min) = $opts->{timeslot} =~ /(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})/;
#	my $endtime = timelocal(0, $Min, $Hour, $Day, $Month-1, $Year);
	my $conf = $NfConf::PluginConf{botnets};

	_DEBUG("timeslot: ". $opts->{timeslot}. " alert: ". $opts->{alert}. " alertfile: ". $opts->{alertfile});

	my $cmd = "nfdump -R $opts->{alertfile} -6 -o \"fmt:\%sa,\%pr,\%da,\%dp,\%fl\" -a -A srcip,dstip,dstport";
	my $time = NfSen::ISO2UNIX($opts->{timeslot});

	if (!open (LINES, "-|")) {
		exec("$cmd") or die "can't start nfdump";
		exit(0);
	}
	open (BOTNETS, "-|", $conf->{import_cmd}) or die "can't import botnets";
	my $botnets;
	while (my ($ip, $port, $proto, $reporter, $timestamp, $timeout, $botnet_id) = split('\|',<BOTNETS>)) {
		_DEBUG("$ip, $port, $proto, $reporter, $timestamp, $timeout, $botnet_id is timed out") and next if ($timeout <= $time);
		$botnets->{$reporter}->{$ip} = {timestamp=>$timestamp, reporter=>$reporter, timeout=>$timeout};
		$botnets->{$reporter}->{$ip}->{botnet_id} = chomp($botnet_id) if (defined $botnet_id and chomp($botnet_id) ne "");
		$botnets->{$reporter}->{$ip}->{port} = $port if ($port ne "");
		$botnets->{$reporter}->{$ip}->{proto} = $proto if ($proto ne "");
	}
	close(BOTNETS);

	<LINES>;<LINES>;# discard the first two lines

#	foreach my $reporter (keys %$botnets) {
#		_DEBUG("reporter: ".$reporter);
#	}
	my $ret = 0;
	while (my $line = <LINES>) {
		my ($SrcIp, $Proto, $DstIp, $DstPort, $Flows) = parseLine($line);
#		_DEBUG($DstIp);
		foreach my $reporter (keys %$botnets) {
			if (exists($botnets->{$reporter}->{$DstIp})) {
#				_DEBUG($reporter.":".$DstIp.":".$botnets->{$reporter}->{$DstIp}->{proto}."-".$Proto."=".($botnets->{$reporter}->{$DstIp}->{proto} eq $Proto).":".$botnets->{$reporter}->{$DstIp}->{port}."-".$DstPort."=".($botnets->{$reporter}->{$DstIp}->{port} eq $DstPort));
				if (
					(!defined $botnets->{$reporter}->{$DstIp}->{port} or $DstPort eq $botnets->{$reporter}->{$DstIp}->{port}) and
					(!defined $botnets->{$reporter}->{$DstIp}->{proto} or $Proto eq $botnets->{$reporter}->{$DstIp}->{proto})
				) {
				#and ($Proto eq $proto)) {
#					Events::process_event({
					my %event = (
						"StopTime"=>"[null]",
						"StartTime"=>"[opt]$time",
						"UpdateTime"=>"$time",
						"Type"=>"[eq]botnet",
						"Level"=>"[opt]notify",
						"Profile"=>"[eq]./live",
						"Source"=>"[eq]".$SrcIp,
						"Destination"=>"[eq]".$DstIp,
						"Times"=>"[add]".$Flows,
						"Reporter"=>"[eq]".$reporter,
						"Timestamp"=>"[opt]".$botnets->{$reporter}->{$DstIp}->{timestamp},
					);
					$event{"Proto"}="[eq]".$botnets->{$reporter}->{$DstIp}->{proto} if defined $botnets->{$reporter}->{$DstIp}->{proto};
					$event{"Port"}="[eq]".$botnets->{$reporter}->{$DstIp}->{port} if defined $botnets->{$reporter}->{$DstIp}->{port};
					$event{"botnet_id"}="[eq]".$botnets->{$reporter}->{$DstIp}->{botnet_id} if defined $botnets->{$reporter}->{$DstIp}->{botnet_id};
					Events::process_event(\%event);

					$ret = 1;
				}
			}
		}
	}
	close(LINES);
	return $ret;
}

sub Init {
	return 1;
}

1;
