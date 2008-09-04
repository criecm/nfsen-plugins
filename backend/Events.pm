#!/usr/bin/perl -w
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
#  $Author:$
#
#  $Id:$
#
#  $LastChangedRevision:$
#
#

=head1 NAME

Events

=head1 SYNOPSIS

	use Events qw(create_event end_event get_event_ids);

	my $id = create_event({
		"StartTime"=>"1185248595",
		"Type"=>"Test",
		"Level"=>"Test",
		"Profile"=>"./live",
		"attr1"=>"This is a test event",
		"attr2"=>["This","is","a","multivalued","attribute"],
	});

	my ids = update_events({
		"Type"=>"[eq]Test",
		"Profile"=>"[eq]./live",
		"attr1"=>"This is a updated test event",
	});

	my $events = get_events({
		"Type"=>"[eq]Test",
		"Profile"=>"[eq]./live",
	});

	my $events = get_event_count({
		"Type"=>"[eq]Test",
	});

=cut

package Events;

use strict;
use warnings;
our @EXPORT = qw(create_event get_event_count get_events update_events process_event key_value_pairs add_value);
use Safe;

use NfConf;
use Nfcomm;
use NfSen; # ISO2UNIX
our $Conf = $NfConf::PluginConf{events};
our $VERSION = 130;
our %cmd_lookup = (
	'create_event' => sub { Nfcomm::socket_send_ok(shift, create_event(shift)); },
	'update_events' => sub { Nfcomm::socket_send_ok(shift, update_events(shift)); },
	'process_event' => sub { Nfcomm::socket_send_ok(shift, process_event(shift)); },
	'get_event_count' => sub { Nfcomm::socket_send_ok(shift, get_event_count(shift)); },
	'get_events_serialized' => sub { Nfcomm::socket_send_ok(shift, get_events_serialized(shift)); },
	'get_events_in_timerange_serialized' => sub { Nfcomm::socket_send_ok(shift, get_events_in_timerange_serialized(shift)); },
);


use Sys::Syslog;
Sys::Syslog::setlogsock('unix');
sub _ERROR { syslog('err', __PACKAGE__.": ".shift); }
sub _DEBUG {
	my $var = shift;
	if (ref $var eq 'HASH') {
		my @pairs = key_value_pairs($var);
		while (scalar(@pairs)>1) {
			syslog('debug', __PACKAGE__.": key: ".shift(@pairs).", value: ".shift(@pairs));
		}

	} else {
		syslog('debug', __PACKAGE__.": ".$var);
	}
	
}

use PHP::Serialization qw(serialize unserialize);
use DBI;
our $dbh = _db_connect();
!$dbh;

my %select_conv = ( #conversion table for selection operators to sql operators
	'eq' => "=",
	'gt' => ">",
	'lt' => "<",
	'ge' => ">=",
	'le' => "<=",
);

my @select_oper =  (keys %select_conv, "null");

my %fixed_fields = ( #Fields that should be filled in the event table and not in the attribute table
	'EventId' => "Numerical",
	'StartTime' => "Numerical",
	'StopTime' => "Numerical",
	'UpdateTime' => "Numerical",
	'Level' => "String",
	'Type' => "String",
	'Profile' => "String",
);

sub _is_fixed_field ($) {
	my $field = shift;
	foreach my $fixed_field (keys %fixed_fields) {
		return 1 if ($field eq $fixed_field);
	}
	return 0;
}

sub _contains ($$) {
	my ($field, $array) = @_;
	foreach my $element (@$array) {
		return 1 if ($field eq $element);
	}
	return 0;
}

=over 4

=cut


=item

=cut

sub process_event($) {
	my $opts = shift;
	if (scalar @{update_events(_remove_attributes($opts, "opt"))}==0) {
		create_event(_remove_attributes(_strip_fields($opts, "opt", "add", keys %select_conv),"null"));
	}
}

sub Cleanup {
}

sub run {
	my ($opts) = @_;
	my $ret = 1;
   _DEBUG("timeslot: ". NfSen::ISO2UNIX($opts->{timeslot}). " alert: ". $opts->{alert}. " alertfile: ". $opts->{alertfile});
	our $unix_time=NfSen::ISO2UNIX($opts->{timeslot});
	my $compartiment = new Safe;
	$compartiment->share(qw($unix_time));
	foreach my $query (@{$Conf->{'periodic_queries'}}) {
		my @pairs = key_value_pairs($query);
		my %updated_query;
		#while (my ($name, $value) = each(%$query)) {
		while (scalar(@pairs)>0) {
			my $name = shift(@pairs);
			my $value = shift(@pairs);
			$value=~s/\#([^\#]*)\#/$compartiment->reval($1)/eg;
			add_value(\%updated_query,$name,$value);
		}
		$ret=0 if (update_events(\%updated_query) == undef);
	}
	return $ret;
}

sub Init {
	return $dbh;
}

sub add_value($$$) {
	my ($list, $name, $value) = @_;	
	if (!exists $list->{$name}) {
		$list->{$name}=$value;
	} else {
		if (ref $list->{$name} eq 'ARRAY') {
			my $attr = $list->{$name};
			push @$attr, $value;
		} else {
			$list->{$name}=[$list->{$name}, $value];
		}
	}
}

=item _remove_attributes

Remove attributes with a certain field

=cut

sub _remove_attributes($$) {
	my ($opts, @opers) = @_;
	my %ret = ();
	my @pairs = key_value_pairs($opts);
	while (scalar(@pairs)>0) {
		my $name = shift(@pairs);
		my $value = shift(@pairs);
		if ($value =~ m/^\s*\[(.+)\].*/) {
			my $oper = $1;
			if ( !_contains($oper, \@opers) ) {
				add_value(\%ret,$name,$value);
			}
		} else {
			add_value(\%ret,$name,$value);
		}
	}
	return \%ret;
}


=item _strip_fields

Strip operation fields from attributes

=cut

sub _strip_fields($$) {
	my ($opts, @opers) = @_;
	my %ret = ();
	my @pairs = key_value_pairs($opts);
	while (scalar(@pairs)>0) {
		my $name = shift(@pairs);
		my $value = shift(@pairs);
		if ($value =~ m/^\s*\[(.+)\](.*)/) {
			my $oper = $1;
			my $val = $2;
			if ( _contains($oper, \@opers) ) {
				add_value(\%ret,$name,$val);
			} else {
				add_value(\%ret,$name,$value);
			}
		} else {
			add_value(\%ret,$name,$value);
		}
	}
	return \%ret;
}

sub key_value_pairs($) {
	my $hash = shift;
	my @pairs;
	while (my ($name, $value) = each(%$hash)) {
		if (ref($value) eq 'ARRAY') {
			foreach my $val (@$value) {
				push(@pairs,$name,$val);
			}
		} else {
			push(@pairs,$name,$value);
		}
	}
	return @pairs;
}


=item create_event

This function adds a new event to the event database. It takes a reference to a hash list 
as argument, which should at least contain a 'StartTime' and a 'Type' key. All hash keys are 
inserted into the database as attributes.

=cut

sub create_event ($) {
	my $opts	= shift;
	_ERROR("create_event called without 'StartTime'") and return undef unless exists $opts->{'StartTime'};
	_ERROR("create_event called without 'UpdateTime'") and return undef unless exists $opts->{'UpdateTime'};
	_ERROR("create_event called without 'Profile'") and return undef unless exists $opts->{'Profile'};
	_ERROR("create_event called without 'Type'") and return undef unless exists $opts->{'Type'};
	$opts->{Level} ||= "Debug";
	my $query;
	if ( !exists $opts->{'StopTime'} ) {
		$query = <<EOSQL;
			INSERT INTO events (starttime, updatetime, level, profile, type) 
			VALUES ($opts->{'StartTime'}, $opts->{'UpdateTime'}, "$opts->{'Level'}", "$opts->{'Profile'}", "$opts->{'Type'}")
EOSQL
	} else {
		$query = <<EOSQL;
			INSERT INTO events (starttime, updatetime, stoptime, level, profile, type) 
			VALUES ($opts->{'StartTime'}, $opts->{'UpdateTime'}, $opts->{'StopTime'}, "$opts->{'Level'}", "$opts->{'Profile'}", "$opts->{'Type'}")
EOSQL
	}
	my $query_handle = $dbh->do($query) || _ERROR("SQL ERROR: ".$dbh->errstr); 
#	my $args = {EventId=>$dbh->func('last_insert_rowid')};
#	my $args = {EventId=>$dbh->last_insert_id};
	my $args = {EventId=>$dbh->{'mysql_insertid'}};
	$opts->{EventId} = $args->{EventId};
	_add_attributes($opts);
	return $args;
}

=item update_events

This function updates a event in the event database. It takes a reference to a hash list as 
argument, that defines which events should be updated, and how. 
The function returns a list of updated event id's, or undef if no events have been updated.

=cut

sub update_events ($) {
	my $opts	= shift;
	_ERROR("update_event called without 'UpdateTime'") and return undef unless exists $opts->{'UpdateTime'};
	my $idlist = get_event_ids($opts);
	return $idlist if (scalar(@$idlist)==0);
	my $condition = "";

	my $query = "INSERT INTO attributes (event_id, name, value) VALUES (?, ?, ?)";
	my $query_handle = $dbh->prepare($query) or _ERROR("SQL ERROR: ".$dbh->errstr);

	my @pairs = key_value_pairs($opts);
	while (scalar(@pairs)>0) {
		my $name = shift(@pairs);
		my $val = shift(@pairs);
		my $oper; my $value;
		if ($val=~m/^\s*\[(\w+)\](.*)/) {
			$oper = $1; $value = $2;
		} else {
			$oper = "set"; $value = $val;
		}
		next if (_contains($oper, \@select_oper));
		if (_is_fixed_field($name)) {
			my $clause;
			if ($oper eq "null") {
				$clause="$name=NULL" ;
			} else {
				if ($oper eq "set") {
					$clause = "$name=\"$value\"";
				} elsif ($oper eq "add") {
					$clause = "$name=$name + $value";
				}
			}
			$condition .= (($condition eq "")?" SET ":" , ").$clause;
		} else {	
			my $clause;
			if ($oper eq "set") {
				$clause = "Value=\"$value\"";
				$query_handle->execute_array({}, $idlist, $name, $value) or _ERROR("SQL ERROR: ".$dbh->errstr);
			} elsif ($oper eq "add") {
				$clause = "Value=Value + $value";
				$dbh->do("UPDATE attributes SET ".$clause." WHERE Name=\"".$name."\" AND Event_id IN (".join(",",@$idlist).")")
					or (_ERROR("SQL ERROR: ".$dbh->errstr)); 
			}
		}
	}
	if ($condition) {
		$dbh->do("UPDATE events ".$condition." WHERE Event_id IN (".join(",",@$idlist).")")
			or (_ERROR("SQL ERROR: ".$dbh->errstr)); 
	}
	return $idlist;
}

=item _add_attributes

This function adds attributes to a event. It takes a reference to a hash list as argument, which should
at least contain a 'EventId' key.

=cut

sub _add_attributes ($) {
	my $opts = shift;
	_ERROR("add_attributes called without 'EventId'") and return unless exists $opts->{'EventId'};
	my $event_id = $opts->{'EventId'};
	my $query = <<EOSQL;
		INSERT INTO attributes (event_id, name, value)
		VALUES ($event_id, ?, ?)
EOSQL
	my $query_handle = $dbh->prepare($query) || _ERROR("SQL ERROR: ".$dbh->errstr); 
	my @pairs = key_value_pairs($opts);
	while (scalar(@pairs)>0) {
		my $name = shift(@pairs);
		my $value = shift(@pairs);
		next if _is_fixed_field($name);
		$query_handle->bind_param(1, $name);
		$query_handle->bind_param(2, $value);
		$query_handle->execute or _ERROR("SQL ERROR: ".$dbh->errstr); 
	}

}

sub _get_where_clause ($) {
	my $opts = shift;
	my $condition = "";
	my $true_condition = "";
	my $true_conditions = 0;
	my $null_condition = "";
	my $null_conditions = 0;
	if ($opts->{'Time_Range'}) {
		my $StartTime = substr($opts->{'StartTime'},4);
		my $StopTime = substr($opts->{'StopTime'},4);
		delete $opts->{'Time_Range'};
		delete $opts->{'StartTime'};
		delete $opts->{'EndTime'};
		$condition = " WHERE (StartTime > $StartTime AND StartTime < $StopTime) OR (StopTime > $StartTime AND StopTime < $StopTime) OR (StartTime < $StartTime AND StopTime > $StopTime)";
	}
	while (my ($name, $oper) = each(%$opts)) {
		if (_is_fixed_field($name)) {
			if (ref $oper ne 'ARRAY') {
				$oper=[$oper];
			}
			foreach my $op (@$oper) {
				next if ($op !~ m/^\s*\[(\w+)\](.*)/);
				my $op = $1;
				next if (!_contains($op, \@select_oper));
				my $value = $2;
				if ($name eq 'event_id') {$name='ev.event_id'; }
				my $clause;
				if ($op eq "null") {
					$clause="$name IS NULL";
				} else {	
					$value="\"$value\"" if ($fixed_fields{$name} eq "String");
					$clause = "$name".$select_conv{$op}."$value";
				}
				$condition .= (($condition eq "")?" WHERE ":" AND ").$clause;
			}
		} else {
			my $true_attribute_conditions=0;
			my $true_attribute_condition="";
			if (ref $oper ne 'ARRAY') {
				$oper=[$oper];
			}
			foreach my $op (@$oper) {
				next if ($op !~ m/^\s*\[(\w+)\](.*)/);
				my $op = $1;
				next if (!_contains($op, \@select_oper));
				my $value = $2;
				if ($op eq "null") {
				$null_condition .= (
					($null_conditions)?" AND ":" right join (select event_id FROM attributes GROUP BY event_id HAVING "
				)."sum(Name=\"$name\")=0";
					$null_conditions++;
				} else {
					if ($op eq "eq") { 
						$value="\"$value\"";
					}
					#TODO implement some distinction between string and numerical comparisons
					$true_attribute_condition .= " AND Value ".$select_conv{$op}.$value;
					$true_attribute_conditions++;
				}
			}
			if ($true_attribute_conditions) {
				$true_condition .= (
					($true_conditions)?" OR ":" right join (select event_id FROM attributes WHERE "
				)."(Name=\"$name\" ".$true_attribute_condition.")";
				$true_conditions++;
			}
		}
	}
	if ($true_conditions) { $true_condition.=" GROUP BY event_id HAVING count(name)=$true_conditions) as qtrue on (ev.event_id=qtrue.event_id) "; }
	if ($null_conditions) { $null_condition.=") as qnull on (ev.event_id=qnull.event_id) "; }
	return "FROM events ev ".$true_condition.$null_condition.$condition;
}

=item get_event_ids

This function takes a reference to a hash as argument and returns the id's of the events which have the 
attribute/value combinations specified in the hash.

=cut

sub get_event_ids ($) {
	my ($opts) = shift;
	my $query = "SELECT ev.event_id "._get_where_clause($opts);
	#_DEBUG($query);
	my $query_handle = $dbh->prepare($query);
	#my $query_handle = $dbh->prepare("SELECT ev.event_id "._get_where_clause($opts));
	if (!$query_handle->execute) {
		_ERROR("SQL ERROR: " . $dbh->errstr);
		return undef;
	} else {
		my $ids = $query_handle->fetchall_arrayref([0]);
		my $ret = [];
		foreach my $id (@$ids) {
			push(@$ret,$id->[0]);
		}
		return $ret;
	}
}

=item get_event_count

This function takes a reference to a hash as argument and returns the number of events that have the 
attribute/value combinations specified in the hash.

=cut

sub get_event_count ($) {
	my $opts	= shift;
	my $query = $dbh->prepare("SELECT count(ev.event_id) "._get_where_clause($opts));
	_DEBUG($opts);
	_DEBUG("SELECT count(ev.event_id) "._get_where_clause($opts));
	$query->execute() || _ERROR("SQL ERROR: ".$dbh->errstr); 
	my @count = $query->fetchrow_array();
	_DEBUG($count[0]);
	my $args = {Count=>$count[0]};
	return $args;
}

=item get_events_serialized

This function takes a reference to a hash as argument and returns the events that have the attribute/value 
combinations specified in the hash. The events are serialized using PHP::Serialization due to restrictions of 
the nfsen frontend-backend communication.

=cut

sub get_events_serialized ($) {
	my $lines = get_events(@_);
	my @ser_lines;
	foreach my $line (@$lines) {
		push @ser_lines, serialize($line);
	}
	my $args = {Lines=>\@ser_lines};
	return $args;
}

sub get_events ($) {
	my $opts	= shift;
	my $limit = "";
	if (exists $opts->{'Limit'}) { $limit.=" LIMIT ".$opts->{'Limit'}; delete $opts->{'Limit'}; }
	if (exists $opts->{'Offset'}) { $limit.=" OFFSET ".$opts->{'Offset'}; delete $opts->{'Offset'}; }
	my $query="SELECT ev.event_id, starttime, stoptime, updatetime, level, profile, type "._get_where_clause($opts)." ORDER BY starttime DESC".$limit;
	_DEBUG($opts);
	_DEBUG($query);
	my @lines;
	my $lines_query = $dbh->prepare($query);
	$lines_query->execute() || _ERROR("SQL ERROR: ".$dbh->errstr); 
	while (my $line = $lines_query->fetchrow_hashref()) {
		my $attributes_query = $dbh->prepare("SELECT name, value FROM attributes WHERE event_id=".$line->{event_id}." ORDER BY name");
		$attributes_query->execute() || _ERROR("SQL ERROR: ".$dbh->errstr); 
		while (my ($name, $value) = $attributes_query->fetchrow_array()) {
			add_value($line, $name, $value);
		}
		push @lines, $line;
	}
	return \@lines;
}

sub get_events_in_timerange ($) {
	my $opts	= shift;
	my $limit = "";
	if (exists $opts->{'Limit'}) { $limit.=" LIMIT ".$opts->{'Limit'}; delete $opts->{'Limit'}; }
	if (exists $opts->{'Offset'}) { $limit.=" OFFSET ".$opts->{'Offset'}; delete $opts->{'Offset'}; }
	my $query="SELECT ev.event_id, starttime, stoptime, updatetime, level, profile, type "._get_where_clause($opts)." ORDER BY starttime DESC".$limit;
	_DEBUG($opts);
	_DEBUG($query);
	my @lines;
	my $lines_query = $dbh->prepare($query);
	$lines_query->execute() || _ERROR("SQL ERROR: ".$dbh->errstr); 
	while (my $line = $lines_query->fetchrow_hashref()) {
		my $attributes_query = $dbh->prepare("SELECT name, value FROM attributes WHERE event_id=".$line->{event_id}." ORDER BY name");
		$attributes_query->execute() || _ERROR("SQL ERROR: ".$dbh->errstr); 
		while (my ($name, $value) = $attributes_query->fetchrow_array()) {
			add_value($line, $name, $value);
		}
		push @lines, $line;
	}
	return \@lines;
}


=item _db_connect

This function connects to the database which is configured in the nfsen configuration file

=cut

sub _db_connect () {
	my $dbh = DBI->connect($Conf->{db_connection_string},$Conf->{db_user},$Conf->{db_passwd});
	if ($dbh) {
		$dbh->{mysql_auto_reconnect} = 1;
	} else {
		_DEBUG("db connection failed: ".DBI->errstr);
	}
	return $dbh;
}

=back

=cut

$dbh
