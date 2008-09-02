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
	while (my ($ip, $port, $proto) = split('\|',<BOTNETS>)) {
		$botnets->{$ip} = {port=>$port, proto=>$proto};
	}
	close(BOTNETS);

	<LINES>;<LINES>;# discard the first two lines

	my $ret = 0;
	while (my $line = <LINES>) {
		my ($SrcIp, $Proto, $DstIp, $DstPort, $Flows) = parseLine($line);
		#_DEBUG($DstIp);
		if (exists($botnets->{$DstIp})) {
			my $proto=$botnets->{$DstIp}->{proto};
			my $port=$botnets->{$DstIp}->{port};
#			_DEBUG(":".$DstIp.":".$proto."-".$Proto."=".($proto eq $Proto).":".$port."-".$DstPort."=".($port eq $DstPort));
			if (
				(!$conf->{match_port} or $DstPort eq $port) and
				(!$conf->{match_proto} or $Proto eq $proto)
			) {
			#and ($Proto eq $proto)) {
				Events::process_event({
					"StopTime"=>"[null]",
					"StartTime"=>"[opt]$time",
					"UpdateTime"=>"$time",
					"Type"=>"[eq]botnet",
					"Level"=>"[opt]notify",
					"Profile"=>"[eq]./live",
					"Source"=>"[eq]".$SrcIp,
					"Destination"=>"[eq]".$DstIp,
					"Proto"=>"[eq]".$Proto,
					"Port"=>"[eq]".$DstPort,
					"Times"=>"[add]".$Flows,
				});
				$ret = 1;
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
