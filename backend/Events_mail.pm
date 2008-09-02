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

package Events_mail;

use Switch;
use strict;
use Time::Local;
use Date::Parse;
use Sys::Syslog;
Sys::Syslog::setlogsock('unix');
use Socket qw(inet_aton AF_INET);
use POSIX;
use NfSen;

use Events qw(update_events get_events key_value_pairs add_value);

use NfConf;
our $Conf = $NfConf::PluginConf{events_mail};

our $VERSION = 130;

sub _ERROR {
	syslog('err', __PACKAGE__.": ".shift);
}

sub _DEBUG {
	syslog('debug', __PACKAGE__.": ".shift);
}

sub run {
	my ($opts) = @_;
	my $ret = 1;
   _DEBUG("timeslot: ". $opts->{timeslot}. " alert: ". $opts->{alert}. " alertfile: ". $opts->{alertfile});
	foreach my $mail (@{$Conf->{'mails'}}) {
		_ERROR("An event should be described by an hash") and next if (!$mail eq 'HASH');
		_ERROR("key 'query' not found in event") and next if (!defined $mail->{query});
		my $query = $mail->{query};
		my @pairs = Events::key_value_pairs($query);
		our $unix_time=NfSen::ISO2UNIX($opts->{timeslot});
		my $events = get_events($query);

		foreach my $event (@$events) {	
			my $compartiment = new Safe;
			our %event=%$event;
			our $unix_time=NfSen::ISO2UNIX($opts->{timeslot});
			$compartiment->permit('localtime');
			$compartiment->share(qw($unix_time %event &lookup_address &to_ISO8601));
			_ERROR("Can't parse subject line: $mail->{'subject'}: ".join(',',$@)) and next unless my $subject=$compartiment->reval("\"".$mail->{'subject'}."\"");
			my $body;
			if (defined $mail->{'template'}) {
				$body = template($event, $compartiment, $Conf->{'template_home'}.'/'.$mail->{'template'});
			} else {
				$body = no_template($event);
			}
			mail($body, $mail->{'to'}, $subject);
		}
		my $compartiment = new Safe;
		our $unix_time=NfSen::ISO2UNIX($opts->{timeslot});
		$compartiment->permit('localtime');
		$compartiment->share(qw($unix_time &lookup_address &to_ISO8601));

		my $action = $mail->{'action'};
		my @pairs = key_value_pairs($action);
		my %updated_action;
		while (scalar(@pairs)>1) {
			my $key = shift(@pairs);
			my $value = shift(@pairs);
			$value=~s/\#([^\#]*)\#/$compartiment->reval($1)/eg;
			add_value(\%updated_action,$key,$value);
		}
		update_events(\%updated_action);
	}
	return $ret;
}

sub lookup_address ($) {
	return gethostbyaddr(inet_aton(shift), Socket::AF_INET); 
}

sub to_ISO8601 ($) {
	strftime("%Y-%m-%dT%H:%M:%S", localtime(shift));
}

sub template($$$) {	
	my ($event, $compartiment, $template) = @_;
	_ERROR("Can't open template: $template") and return unless open(TEMPLATE, '<', $template);
	my $line;
	while (my $l .= <TEMPLATE>) {
		$line.=$l;
	}
	_ERROR("Can't parse template: ".join(',',$@)) and next unless my $parsed_lines=$compartiment->reval($line);
	my @ret=($parsed_lines);
	close TEMPLATE;
	return \@ret;
}


sub no_template($) {	
	my ($event) = @_;
	my @mail_body = ();

	my @pairs = key_value_pairs($event);
	while (scalar(@pairs)>1) {
		my $key = shift(@pairs);
		my $value = shift(@pairs);
		push (@mail_body, "$key=$value\n");
	}
	return \@mail_body;
}

sub mail ($$$) {
	my ($mail_body, $to, $subject) = @_;

	my $mail_header = new Mail::Header( [
		"From: "   .$NfConf::MAIL_FROM,
		"To: "     .join(",",@$to),
		"Subject: ".$subject,
	]);
	
	my $mail = new Mail::Internet(
		Header => $mail_header,
		Body   => $mail_body,
	);

	my @sent_to = $mail->smtpsend(
		Host     => $NfConf::SMTP_SERVER,
		Hello    => $NfConf::SMTP_SERVER,
		MailFrom => $NfConf::MAIL_FROM,
	);

	# Do we have failed receipients?
	my %_tmp;
	$_tmp{@$to} = 1;
	delete $_tmp{@sent_to};

	foreach my $rcpt ( keys %_tmp ) {
		_ERROR("Failed to send alert email to: $rcpt");
	}
}


sub Init {
	return 1;
}

1;

