<?php
/*
 *  vim: ts=4 sw=3:
 *
 *	Copyright (c) 2007, SURFnet B.V. 
 *	All rights reserved.
 *
 *	Redistribution and use in source and binary forms, with or without modification, 
 *	are permitted provided that the following conditions are met:
 *
 *	*	Redistributions of source code must retain the above copyright notice, this
 *		list of conditions and the following disclaimer.
 *	*	Redistributions in binary form must reproduce the above copyright notice, this
 *		list of conditions and the	following disclaimer in the documentation and/or
 *		other materials provided with the distribution.
 *	*	Neither the name of the SURFnet B.V. nor the names of its contributors may be
 *		used to endorse or promote products derived from this software without specific 
 *		prior written permission.
 *
 *	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY 
 *	EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES 
 *	OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT 
 *	SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
 *	INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 *	TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR 
 *	BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON	ANY THEORY OF LIABILITY, WHETHER IN 
 *	CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
 *	ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH 
 *	DAMAGE.
 *
 *
 *  $Author:$
 *
 *  $Id:$
 *
 *  $LastChangedRevision:$
 *
 *
 */

#$ip_lookup=1;

// Required functions
/* 
 * This function is  called prior to any output to the web browser and is intended
 * for the plugin to parse possible form data. This function is called only, if this
 * plugin is selected in the plugins tab
 */
function Events_ParseInput( $plugin_id ) {
} // End of alarm_ParseInput

function is_ip_attribute( $attr ) {
	return $attr === "Source" or $attr === "Destination";
}

function markup_attribute( $attr, $val) {
	global $ip_lookup;
	if (is_ip_attribute($attr) and ($ip_lookup)) 
		return "<a href='#null' onClick='lookup(\"$val\", this, event)' title='lookup $val'>$val</a>";
	else
		return $val;
}

function show_attributes( $line ) {
	$ret="";
	foreach ($line as $name=>$value) {
		if ($name!='event_id' and $name!='starttime' and $name!='stoptime' and $name!='updatetime' and $name!='level' and $name!='type' and $name!='profile') {
			if (is_array($value)) {
				$curline="<B>".$name."</B>=";
				foreach($value as $val) {
					$curline.=markup_attribute($name,$val).", ";
				}
				$ret .= $curline."<br>";
#				$ret .= markup_attribute($name, $value)."<br>";
			} else
				$ret .= "<B>".$name."</B>=".markup_attribute($name, $value)."<br>";
		}
	}
	return $ret;
}

function show_actions( $line ) {
	$ret="";
	if (array_key_exists('Graph',$line) and array_key_exists('Channel',$line)) {
		if (isset($line['stoptime'])) {
			$endTime=$line['stoptime'];
		} else {
			$endTime=time()-300;
			$endTime-=$endTime % 300;
		}
		$vars=array(
			'tab'=>2,
			'sub_tab'=>'-',
			'profileswitch'=>$line['profile'],
			'channellist'=>$line['Channel'],
			'detail_opts/proto'=>$line['Proto'],
			'detail_opts/type'=>$line['Graph'],
			'detail_opts/wsize'=>1,
			'detail_opts/cursor_mode'=>1,
			'tend'=>$endTime,
			'tleft'=>$line['starttime'],
			#-300,
			'tright'=>$endTime,
			#-300,
			'detail_opts/logscale'=>'-',
			'detail_opts/ratescale'=>'-',
			'detail_opts/linegraph'=>'-',
		);
		$bookmark = urlencode(base64_encode(implode('|', $vars)));
		#print(implode('|',$vars));
		$ret .= "<a href=\"$self?bookmark=".$bookmark."\">show details</a>";
	}
	return $ret;
}

function DisplayTable( $count, $Offset, $Limit, $filter ) {
?>
	<TABLE BORDER=0>
		<TR BGCOLOR="#6699cc">
			<TD> ID </TD>
			<TD> Starttime </TD>
			<TD> Stoptime </TD>
			<TD> Updatetime </TD>
			<TD> Level </TD>
			<TD> Profile </TD>
			<TD> Type </TD>
			<TD> Attributes </TD>
			<TD> Actions </TD>
		</TR>
<?php
	$output = nfsend_query("Events::get_events_serialized", array_merge(array('Limit'=>$Limit,'Offset'=>$Offset),$filter));
	foreach ($output['Lines'] as $serline) {
		$line = unserialize($serline);

?>
		<TR BGCOLOR="#dee7ec">
			<TD><?=$line['event_id']?></TD>
			<TD><?=strftime("%c",$line['starttime'])?></TD>
			<TD><?=isset($line->{"stoptime"})?strftime("%c",$line['stoptime']):"active"?></TD>
			<TD><?=strftime("%c",$line['updatetime'])?></TD>
			<TD><?=$line['level']?></TD>
			<TD><?=$line['profile']?></TD>
			<TD><?=$line['type']?></TD>
			<TD><?=show_attributes($line)?></TD>
			<TD><?=show_actions($line)?></TD>
		</TR>
<?php
	}
?>
	</TABLE> 

<?php
}

function build_filter_array( $Filter ) {
	$filter_array=array();
	foreach (split(' +',$Filter) as $Filter_item) {
		$val = explode(':',$Filter_item);
		if ($val[0] != "")
			if (!array_key_exists($val[0],$filter_array))
				$filter_array[$val[0]]=$val[1];
			else 
				if (!is_array($filter_array[$val[0]])) 
					$filter_array[$val[0]]=array($filter_array[$val[0]],$val[1]);
				else
					$filter_array[$val[0]][]=$val[1];
	}
	return $filter_array;
}

/*
 * This function is called after the header with the navigation bar have been sent to the
 * browser. It's now up to this function what to display.
 * This function is called only, if this plugin is selected in the plugins tab
 */
function Events_Run( $plugin_id ) {	
	list ($process_form, $has_errors) = ParseForm(array(
		'Limit'=>array( "required"=>0, "default"=>"10", "allow_null"=>1, "match"=>"/[0-9]+/", "validate"=>NULL ),
		'Offset'=>array( "required"=>0, "default"=>"0", "allow_null"=>1, "match"=>"/[0-9]+/", "validate"=>NULL ),
		#'Filter'=>array( "required"=>0, "default"=>"", "allow_null"=>1, "match"=>"/^(\s*\w+:(\[.+\])?\w*)*$/", "validate"=>NULL ),
		'Filter'=>array( "required"=>0, "default"=>"", "allow_null"=>1, "match"=>NULL, "validate"=>NULL ),
	));
#	print $has_errors;
	$Offset = $process_form["Offset"];
	$Limit = $process_form["Limit"];
	$Filter = $process_form["Filter"];
	$filter_array = build_filter_array($Filter);
	$count = nfsend_query("Events::get_event_count", $filter_array);
	$count = $count['Count'];
?>	
	<FORM METHOD="post" ACTION="<?=$self?>">
		<INPUT TYPE="hidden" NAME="Limit" VALUE="<?=$process_form["Limit"]?>">
		<INPUT TYPE="hidden" NAME="Offset" VALUE="<?=($Offset<$Limit)?0:$Offset-$Limit ?>">
		<INPUT TYPE="text" NAME="Filter" VALUE="<?=$Filter ?>">
		<INPUT TYPE="submit" VALUE="filter">
	</FORM>
<?php
	if ($count>0) {
		print "Showing events ".($Offset+1)." to ".((($Offset+$Limit)>$count)?$count:$Offset+$Limit)." of ".$count;
		DisplayTable( $count, $Offset, $Limit, $filter_array );
?>
	<FORM METHOD="post" ACTION="<?=$self?>">
		<INPUT TYPE="hidden" NAME="Limit" VALUE="<?=$process_form["Limit"]?>">
		<INPUT TYPE="hidden" NAME="Offset" VALUE="<?=($Offset<$Limit)?0:$Offset-$Limit ?>">
		<INPUT TYPE="hidden" NAME="Filter" VALUE="<?=$Filter ?>">
		<INPUT TYPE="submit" VALUE="<">
	</FORM>

	<FORM METHOD="post" ACTION="<?=$self?>">
		<INPUT TYPE="hidden" NAME="Limit" VALUE="<?=$Limit?>">
		<INPUT TYPE="hidden" NAME="Offset" VALUE="<?=($Offset>=($count-$Limit))?$Offset:($Offset+$Limit)?>">
		<INPUT TYPE="hidden" NAME="Filter" VALUE="<?=$Filter ?>">
		<INPUT TYPE="submit" VALUE=">">
	</FORM>
<?php
		global $ip_lookup;
		if ($ip_lookup) {
	?>
		</script>
			<script language="Javascript" src="js/detail.js" type="text/javascript">
		</script>
		<div id="lookupbox">
			<div id="lookupbar" align="right" style="background-color:olivedrab"><img src="icons/close.gif"
				onmouseover="this.style.cursor='pointer';" onClick="hidelookup()" title="Close lookup box"></div>
			<iframe id="cframe" src="" frameborder="0" width=100% height=100%></iframe>
		</div>

<?php
		}
	} else {
		print "No events".(($Filter!="")?" for the selected filter":"");
	};

}
?>
