#!/usr/bin/env perl -w
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
#####################################################
#
#  xCAT plugin package to handle the following commands.
#	 mkdsklsnode, rmdsklsnode, mknimimage,  
#	 rmnimimage, nimnodecust,  & nimnodeset
#
#####################################################

package xCAT_plugin::aixinstall;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}
use lib "$::XCATROOT/lib/perl";
use Sys::Hostname;
use File::Basename;
use xCAT::NodeRange;
use xCAT::Schema;
use xCAT::Utils;
use xCAT::DBobjUtils;
use XML::Simple;
use Data::Dumper;
use Getopt::Long;
use xCAT::MsgUtils;
use strict;
use Socket;
use File::Path;

# options can be bundled up like -vV
Getopt::Long::Configure("bundling");
$Getopt::Long::ignorecase = 0;


#------------------------------------------------------------------------------

=head1    aixinstall

This program module file supports the mkdsklsnode, rmdsklsnode,
rmnimimage, mknimimage, nimnodecust, & nimnodeset commands.


=cut

#------------------------------------------------------------------------------

=head2    xCAT for AIX support

=cut

#------------------------------------------------------------------------------

#----------------------------------------------------------------------------

=head3  handled_commands

        Return a list of commands handled by this plugin

=cut

#-----------------------------------------------------------------------------

sub handled_commands
{
    return {
            mknimimage => "aixinstall",
			rmnimimage => "aixinstall",
            mkdsklsnode => "aixinstall",
			rmdsklsnode => "aixinstall",
			nimnodeset => "aixinstall",
			nimnodecust => "aixinstall"
            };
}

#-------------------------------------------------------

=head3  preprocess_request

  Check and setup for hierarchy

=cut

#-------------------------------------------------------
sub preprocess_request
{
    my $req = shift;
    my $cb  = shift;
	my $sub_req = shift;

	my $command  = $req->{command}->[0];
    $::args     = $req->{arg};
    $::filedata = $req->{stdin}->[0];

    my %sn;

	# don't want preprocess to run on service node but _xcatdest is not set??
    #if ($req->{_xcatdest}) { return [$req]; }    #exit if preprocessed

    my $nodes    = $req->{node};
    my $service  = "xcat";
    my @requests;
	my $lochash;
	my $nethash;
	my $nodehash;
	my $imagehash;
	my $attrs;
	my $locs;

	# get this systems name as known by xCAT management node
    my $Sname = &myxCATname();
    chomp $Sname;

	# get the name of the primary NIM server
	#	- either the NIMprime attr of the site table or the management node
	my $nimprime = &getnimprime();
    chomp $nimprime;

	# if this is a service node and not the NIM primary then just return
    #       don't want to do preprocess again

	if (xCAT::Utils->isServiceNode() && !is_me($nimprime) ){
        return [$req];
    }

	#
	# preprocess each cmd - (help, version, gather data etc.)
	#	set up requests for service nodes
	#
	if ($command =~ /mknimimage/) {

		my $reqcopy = {%$req};
        $reqcopy->{'_xcatdest'} = $nimprime;
        push @requests, $reqcopy;

		return \@requests;
    }

    if ($command =~ /rmnimimage/) {
		# take care of -h etc.
		# also get osimage hash to pass on!!
		my ($rc, $imagehash) = &prermnimimage($cb);
		if ( $rc ) { # either error or -h was processed etc.
            my $rsp;
            if ($rc eq "1") {
                $rsp->{errorcode}->[0] = $rc;
                push @{$rsp->{data}}, "Return=$rc.";
                xCAT::MsgUtils->message("E", $rsp, $cb, $rc);
            }
            return undef;
        }

		# need to remove NIM res from all SNs
		# get all the service nodes
		my @nlist = xCAT::Utils->list_all_nodes;
		my $sn;
		if (\@nlist) {
			$sn = xCAT::Utils->get_ServiceNode(\@nlist, $service, "MN");
		}

		# if something more than -h etc. then pass on the request
		if (defined($imagehash)) {
			foreach my $snkey (keys %$sn) {
				my $reqcopy = {%$req};
				$reqcopy->{'_xcatdest'} = $snkey;
				if ($imagehash) {
					# add tags to the hash keys that start with a number
					&taghash($imagehash);  #?????
					$reqcopy->{'imagehash'} = $imagehash;
				}
				push @requests, $reqcopy;
			}
			return \@requests;
		} else {
			return undef;
		}
    }

	#
	# get the hash of service nodes - for the nodes that were provided
	#
	my $sn;
	if ($nodes) {
		$sn = xCAT::Utils->get_ServiceNode($nodes, $service, "MN");
	}

	# these commands might be merged some day??
    if (($command =~ /nimnodeset/) || ($command =~ /mkdsklsnode/)) {
		my ($rc, $nodehash, $nethash, $imagehash, $lochash, $attrs) = &prenimnodeset($cb, $command);

		if ( $rc ) { # either error or -h was processed etc.
            my $rsp;
            if ($rc eq "1") {
                $rsp->{errorcode}->[0] = $rc;
                push @{$rsp->{data}}, "Return=$rc.";
                xCAT::MsgUtils->message("E", $rsp, $cb, $rc);
            }
            return undef;
        }

		# set up the requests to go to the service nodes
		foreach my $snkey (keys %$sn) {
			my $reqcopy = {%$req};
			$reqcopy->{node} = $sn->{$snkey};
			$reqcopy->{'_xcatdest'} = $snkey;

			# might as well pass along anything we had to look up
            #   in the preprocessing
            if ($nodehash) {
				# add tags to the hash keys that start with a number
                #  XML cannot handle keys that start with number
                &taghash($nodehash);
                $reqcopy->{'nodehash'} = $nodehash;
            }

			if ($imagehash) {
                &taghash($imagehash);
                $reqcopy->{'imagehash'} = $imagehash;
            }
			
			if ($lochash) {
                &taghash($lochash);
                $reqcopy->{'lochash'} = $lochash;
            }

			if ($nethash) {
                &taghash($nethash);
                $reqcopy->{'nethash'} = $nethash;
            }

			if ($attrs) {
                $reqcopy->{'attrval'} = $attrs;
            }
            push @requests, $reqcopy;
		}
		return \@requests;
    }

	if ($command =~ /nimnodecust/) {
		# handle -h etc.
		# copy stuff to service nodes 
        my ($rc, $bndloc) = &prenimnodecust($cb, $nodes);
		if ( $rc ) { # either error or -h was processed etc.
            my $rsp;
            if ($rc eq "1") {
                $rsp->{errorcode}->[0] = $rc;
                push @{$rsp->{data}}, "Return=$rc.";
                xCAT::MsgUtils->message("E", $rsp, $cb, $rc);
            }
            return undef;
        }

		# set up the requests to go to the service nodes
        #   all get the same request
        foreach my $snkey (keys %$sn) {
            my $reqcopy = {%$req};
            $reqcopy->{node} = $sn->{$snkey};
            $reqcopy->{'_xcatdest'} = $snkey;
			if ($bndloc) {
				# add tags to the hash keys that start with a number
                &taghash($bndloc);
                $reqcopy->{'lochash'} = $bndloc;
            }

            push @requests, $reqcopy;
        }
        return \@requests;
    }

    if ($command =~ /rmdsklsnode/) {
		# handle -h etc.
        my $rc =  &prermdsklsnode($cb);

		if ( $rc ) { # either error or -h was processed etc.
            my $rsp;
            if ($rc eq "1") {
                $rsp->{errorcode}->[0] = $rc;
                push @{$rsp->{data}}, "Return=$rc.";
                xCAT::MsgUtils->message("E", $rsp, $cb, $rc);
            }
            return undef;
		} else {

			# set up the requests to go to the service nodes
			#   all get the same request
			foreach my $snkey (keys %$sn) {
				my $reqcopy = {%$req};
				$reqcopy->{node} = $sn->{$snkey};
				$reqcopy->{'_xcatdest'} = $snkey;

				push @requests, $reqcopy;
			}
			return \@requests;
		}
    }
	return undef;
}

#----------------------------------------------------------------------------

=head3   process_request

        Check for xCAT command and call the appropriate subroutine.

        Arguments:

        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------

sub process_request
{

    my $request  = shift;
    my $callback = shift;
    my $sub_req = shift; 
    my $ret;
    my $msg;
    
    $::callback=$callback;

	# convert the hashes back to the way they were passed in
    #   XML created arrays - we need to strip them out
    my $flatreq=&restore_request($request, $callback);

	my $command  = $flatreq->{command};
    $::args     = $flatreq->{arg};
    $::filedata = $flatreq->{stdin}->[0];

	# set the data passed in by the preprocess_request routine
    my $nodehash = $flatreq->{'nodehash'};
    my $nethash = $flatreq->{'nethash'};
    my $imagehash = $flatreq->{'imagehash'};
    my $lochash = $flatreq->{'lochash'};
    my $attrval = $flatreq->{'attrval'};
    my $nodes    = $flatreq->{node};

    # figure out which cmd and call the subroutine to process
    if ($command eq "mkdsklsnode")
    {
        ($ret, $msg) = &mkdsklsnode($callback, $nodes, $nodehash, $nethash, $imagehash, $lochash, $sub_req);
    }
    elsif ($command eq "mknimimage")
    {
        ($ret, $msg) = &mknimimage($callback);
    }
	elsif ($command eq "rmnimimage")
	{
		($ret, $msg) = &rmnimimage($callback, $imagehash);

	}
	elsif ($command eq "rmdsklsnode")
	{
		($ret, $msg) = &rmdsklsnode($callback,$nodes);
	} 
	elsif ($command eq "nimnodeset")
	{
		($ret, $msg) = &nimnodeset($callback, $nodes, $nodehash, $nethash, $imagehash, $lochash, $sub_req);
	}

	elsif ($command eq "nimnodecust")
    {
        ($ret, $msg) = &nimnodecust($callback, $lochash, $nodes);
    }

	if ($ret > 0) {
		my $rsp;

		if ($msg) {
			push @{$rsp->{data}}, $msg;
		} else {
			push @{$rsp->{data}}, "Return=$ret.";
		}

		$rsp->{errorcode}->[0] = $ret;
		
		xCAT::MsgUtils->message("E", $rsp, $callback, $ret);

	}
	return 0;
}

#----------------------------------------------------------------------------

=head3   nimnodeset 

        Support for the nimnodeset command.

		Does the NIM setup for xCAT cluster nodes.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:
        Example:
        Comments:

=cut

#-----------------------------------------------------------------------------
sub nimnodeset
{
    my $callback = shift;
	my $nodes = shift;
    my $nodehash = shift;
    my $nethash = shift;
    my $imaghash = shift;
    my $locs = shift;
    my $sub_req = shift;

	my %lochash = %{$locs};
    my %objhash = %{$nodehash}; # node definitions
    my %nethash = %{$nethash};
    my %imagehash = %{$imaghash}; # osimage definition
    my @nodelist = @$nodes;

	my $error=0;
	my @nodesfailed;
	my $image_name;

	# some subroutines require a global callback var
	#	- need to change to pass in the callback 
	#	- just set global for now
    $::callback=$callback;

	my $Sname = &myxCATname();

	if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
        &nimnodeset_usage($callback);
		return 0;
    }

	# parse the options
	if(!GetOptions(
		'f|force'	=> \$::FORCE,
		'h|help'    => \$::HELP,
		'i=s'       => \$::OSIMAGE,
		'verbose|V' => \$::VERBOSE,
		'v|version' => \$::VERSION,))
	{
		&nimnodeset_usage($callback);
		return 1;
	}

	my %objtype;
	my %attrs;  	# attr=val pairs from cmd line 
	my %cmdargs; 	# args for the "nim -o bos_inst" cmd line
	my @machines;	# list of defined NIM machines
	my @nimrestypes;	# list of NIM resource types 
	my @nodesfailed;	# list of xCAT nodes that could not be initialized

	# the first arg should be a noderange - the other should be attr=val
    #  - put attr=val operands in %attrs hash
    while (my $a = shift(@ARGV))
    {
        if ($a =~ /=/) {
            # if it has an "=" sign its an attr=val - we hope
            my ($attr, $value) = $a =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;
            if (!defined($attr) || !defined($value))
            {
                my $rsp;
                $rsp->{data}->[0] = "Incorrect \'attr=val\' pair - $a\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 1;
            }
            # put attr=val in hash
			$attrs{$attr} = $value;
        }
    }

    #
    #  Get a list of the defined NIM machines
    #
    my $cmd = qq~/usr/sbin/lsnim -c machines | /usr/bin/cut -f1 -d' ' 2>/dev/nu
ll~;
    @machines = xCAT::Utils->runcmd("$cmd", -1);
	# don't fail - maybe just don't have any defined!

	#
    #  Get a list of all nim resource types
    #
    my $cmd = qq~/usr/sbin/lsnim -P -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
    @nimrestypes = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
        my $rsp;
        push @{$rsp->{data}}, "$Sname: Could not get NIM resource types.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	#
	# get all the image names needed and make sure they are defined on the 
	# local server
	#
	my @image_names;
	my %nodeosi;
	foreach my $node (@nodelist) {
		if ($::OSIMAGE){
			# from the command line
			$nodeosi{$node} = $::OSIMAGE;
		} else {
			if ( $objhash{$node}{profile} ) {
				$nodeosi{$node} = $objhash{$node}{profile};
			} else {
				my $rsp;
				push @{$rsp->{data}}, "$Sname: Could not determine an OS image name for node \'$node\'.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				push(@nodesfailed, $node);
				$error++;
				next;
			}
		}
		if (!grep (/^$nodeosi{$node}$/, @image_names)) {
			push(@image_names, $nodeosi{$node});
		}
	}
	
	if (scalar(@image_names) == 0)  {
		# if no images then error
		return 1;
	}

	#
    # get the primary NIM master - default to management node
    #
	my $nimprime = &getnimprime();
	chomp $nimprime;

	#
    # if this isn't the NIM primary then make sure the local NIM defs
    #   have been created etc.
    #
 	if (!&is_me($nimprime)) {
        &make_SN_resource($callback, \@nodelist, \@image_names, \%imagehash, \%lochash, \%nethash);
    }

	my $error=0;
    foreach my $node (@nodelist)
    {
		
		# get the image name to use for this node
		my $image_name = $nodeosi{$node};
        chomp $image_name;

		# check if node is in ready state
		my $shorthost;
		($shorthost = $node) =~ s/\..*$//;
        chomp $shorthost;
		my $cstate = &get_nim_attr_val($shorthost, "Cstate", $callback);
		if ( defined($cstate) && (!($cstate =~ /ready/)) ){
			if ($::FORCE) {
				# if it's not in a ready state then reset it
				if ($::VERBOSE) {
					my $rsp;
					push @{$rsp->{data}}, "$Sname: Reseting NIM definition for $shorthost.\n";
					xCAT::MsgUtils->message("I", $rsp, $callback);
				}

				my $rcmd = "/usr/sbin/nim -Fo reset $shorthost;/usr/sbin/nim -Fo deallocate -a subclass=all $shorthost";
				my $output = xCAT::Utils->runcmd("$rcmd", -1);
            	if ($::RUNCMD_RC  != 0) {
                	my $rsp;
                	push @{$rsp->{data}}, "$Sname: Could not reset the existing NIM object named \'$shorthost\'.\n";
                	if ($::VERBOSE) {
                    	push @{$rsp->{data}}, "$output";
                	}
                	xCAT::MsgUtils->message("E", $rsp, $callback);
                	$error++;
                	push(@nodesfailed, $node);
                	next;
            	}
			} else {

				my $rsp;
				push @{$rsp->{data}}, "$Sname: The NIM machine named $shorthost is not in the ready state and cannot be initialized.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
                $error++;
                push(@nodesfailed, $node);
                next;

			}
		}

		# set the NIM machine type
		my $type="standalone";
		if ($imagehash{$image_name}{nimtype} ) {
			$type = $imagehash{$image_name}{nimtype};
		}
		chomp $type;

		if ( !($type =~ /standalone/) ) {
            #error - only support standalone for now
            #   - use mkdsklsnode for diskless/dataless nodes
            my $rsp;
            push @{$rsp->{data}}, "$Sname: Use the mkdsklsnode command to initialize diskless/dataless nodes.\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            $error++;
            push(@nodesfailed, $node);
            next;
        }

		# set the NIM install method (rte or mksysb)
        my $method="rte";
        if ($imagehash{$image_name}{nimmethod} ) {
            $method = $imagehash{$image_name}{nimmethod};
        }
        chomp $method;
		
		# by convention the nim name is the short hostname of our node
		my $nim_name;
		($nim_name = $node) =~ s/\..*$//;
		chomp $nim_name;
		if (!grep(/^$nim_name$/, @machines)) {
			my $rsp;
			push @{$rsp->{data}}, "$Sname: The NIM machine \'$nim_name\' is not defined.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
            $error++;
            push(@nodesfailed, $node);
            next;
		}

		# figure out what resources and options to pass to NIM "bos_inst"
		#  first set %cmdargs to osimage info then set to cmd line %attrs info
		#  TODO - what about resource groups????

		#  add any resources that are included in the osimage def
		#		only take the attrs that are actual NIM resource types
		my $script_string="";
        my $bnd_string="";

        foreach my $restype (sort(keys %{$imagehash{$image_name}})) {
            # restype is res type (spot, script etc.)
            # resname is the name of the resource (61spot etc.)
            my $resname = $imagehash{$image_name}{$restype};

			# if the attr is an actual resource type then add it 
			#	to the list of args
            if (grep(/^$restype$/, @nimrestypes)) {
                if ($resname) {
					# handle multiple script & installp_bundles
                    if ( $restype eq 'script') {
                        foreach (split /,/,$resname) {
                            chomp $_;
                            $script_string .= "-a script=$_ ";
                        }
                    } elsif ( $restype eq 'installp_bundle') {
                        foreach (split /,/,$resname) {
                            chomp $_;
                            $bnd_string .= "-a installp_bundle=$_ ";
                        }

                    } else {
                        # ex. attr=spot resname=61spot
                        $cmdargs{$restype} = $resname;
                    }
                }

            }
        }

		# now add/overwrite with what was provided on the cmd line
		if (defined(%attrs)) {
			foreach my $attr (keys %attrs) {
				# assume each attr corresponds to a valid
                #   "nim -o bos_inst" attr
                # handle multiple script & installp_bundles
                if ( $attr eq 'script') {
                    $script_string = "";
                    foreach (split /,/,$attrs{$attr}) {
                        chomp $_;
                        $script_string .= "-a script=$_ ";
                    }
                } elsif ( $attr eq 'installp_bundle'){
                    $bnd_string="";
                    foreach (split /,/,$attrs{$attr}) {
                        chomp $_;
                        $bnd_string .= "-a installp_bundle=$_ ";
                    }

                } else {
                    # ex. attr=spot resname=61spot
                    $cmdargs{$attr} = $attrs{$attr};
                }
			}
		}

		if ($method eq "mksysb") {
			$cmdargs{source} = "mksysb";

			# check for req attrs

		} elsif ($method eq "rte") {
			$cmdargs{source} = "rte";

			# TODO - check for req attrs
		}

		# must add script res
		#$cmdargs{script} = $resname;
		#$cmdargs{script} = "xcataixpost";

		# set boot_client
		if (!defined($cmdargs{boot_client})) {
			$cmdargs{boot_client} = "no";
		}

		# set accept_licenses
        if (!defined($cmdargs{accept_licenses})) {
            $cmdargs{accept_licenses} = "yes";
        }

		# create the cmd line args
		my $arg_string=" ";
		foreach my $attr (keys %cmdargs) {
			$arg_string .= "-a $attr=\"$cmdargs{$attr}\" ";
		}

		if ($script_string) {
            $arg_string .= "$script_string";
        }

        if ($bnd_string) {
            $arg_string .= "$bnd_string";
        }

		my $initcmd;
		$initcmd="/usr/sbin/nim -o bos_inst $arg_string $nim_name 2>&1";

		if ($::VERBOSE) {
            my $rsp;
            push @{$rsp->{data}}, "$Sname: Running- \'$initcmd\'\n";
            xCAT::MsgUtils->message("I", $rsp, $callback);
        }

		my $output = xCAT::Utils->runcmd("$initcmd", -1);
		if ($::RUNCMD_RC  != 0)
		{
			my $rsp;
			push @{$rsp->{data}}, "$Sname: The NIM bos_inst operation failed for \'$nim_name\'.\n";
			if ($::VERBOSE) {
				push @{$rsp->{data}}, "$output";
			}
			xCAT::MsgUtils->message("E", $rsp, $callback);
			$error++;
            push(@nodesfailed, $node);
			next;
		}
	} # end - for each node

	# update the node definitions with the new osimage - if provided
	my %nodeattrs;
	foreach my $node (keys %objhash) {
        chomp $node;

        if (!grep(/^$node$/, @nodesfailed)) {
            # change the node def if we were successful
            $nodeattrs{$node}{objtype} = 'node';
            $nodeattrs{$node}{os} = "AIX";
            if ($::OSIMAGE) {
                $nodeattrs{$node}{profile} = $::OSIMAGE;
            }
        }
    }

	if (xCAT::DBobjUtils->setobjdefs(\%nodeattrs) != 0) {
		my $rsp;
		push @{$rsp->{data}}, "$Sname: Could not write data to the xCAT database.\n";
		xCAT::MsgUtils->message("E", $rsp, $::callback);
		$error++;
	}

# TODO
# use xdcp and assume the proper setup has been done by servicenode
#   post script??
if (0) {
	# update the .rhosts file on the server so the rcp from the node works
	if ($::VERBOSE) {
        my $rsp;
        push @{$rsp->{data}}, "Updating .rhosts on $Sname.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }
    if (&update_rhosts(\@nodelist, $callback) != 0) {
        my $rsp;
        push @{$rsp->{data}}, "$Sname: Could not update the /.rhosts file.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        $error++;
    }
}

	# restart inetd
	if ($::VERBOSE) {
        my $rsp;
        push @{$rsp->{data}}, "Restarting inetd on $Sname.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }
	my $scmd = "stopsrc -s inetd";
    my $output = xCAT::Utils->runcmd("$scmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not stop inetd on $Sname.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        $error++;
    }
	my $scmd = "startsrc -s inetd";
    my $output = xCAT::Utils->runcmd("$scmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not start inetd on $Sname.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        $error++;
    }

	if ($error) {
		my $rsp;
		push @{$rsp->{data}}, "$Sname: One or more errors occurred when attempting to initialize AIX NIM nodes.\n";

		if ($::VERBOSE && (defined(@nodesfailed))) {
			push @{$rsp->{data}}, "$Sname: The following node(s) could not be initialized.\n";
			foreach my $n (@nodesfailed) {
				push @{$rsp->{data}}, "$n";
			}
		}

		xCAT::MsgUtils->message("I", $rsp, $callback);
		return 1;
	} else {
		my $rsp;
		push @{$rsp->{data}}, "$Sname: AIX/NIM nodes were initialized.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);

		return 0;
	}
	return 0;
}

#----------------------------------------------------------------------------

=head3   mknimimage


		Creates an AIX/NIM image 

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Usage:

		mknimimage [-V] [-f | --force] [-l location] [-s image_source]
		   [-i current_image] image_name [attr=val [attr=val ...]]

		Comments:

=cut

#-----------------------------------------------------------------------------
sub mknimimage
{
	my $callback = shift;

	my $lppsrcname; # name of the lpp_source resource for this image
	$::image_name; # name of xCAT osimage to create
	my $spot_name;  # name of SPOT/COSI  default to image_name
	my $rootres;    # name of the root resource
	my $dumpres;    #  dump resource
	my $pagingres;  # paging
	my $currentimage; # the image to copy
	%::attrres;   # NIM resource type and names passed in as attr=val
	my %newres;   # NIM resource type and names create by this cmd
	%::imagedef;    # osimage info provided by "-i" option
	my %osimagedef; # NIM resource type and names for the osimage def 
	my $bosinst_data_name;
	my $resolv_conf_name;
	my $mksysb_name;
	my $lpp_source_name;
	my $root_name;
	my $dump_name;

	if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
        &mknimimage_usage($callback);
        return 0;
    }

	# parse the options
	Getopt::Long::Configure("no_pass_through");
	if(!GetOptions(
		'b=s'		=> \$::SYSB,
		'f|force'	=> \$::FORCE,
		'h|help'     => \$::HELP,
		's=s'       => \$::opt_s,
	 	'r|sharedroot'  => \$::SHAREDROOT,
		'l=s'       => \$::opt_l,
		'i=s'       => \$::opt_i,
		't=s'		=> \$::NIMTYPE,
		'm=s'		=> \$::METHOD,
		'n=s'		=> \$::MKSYSBNODE,
		'verbose|V' => \$::VERBOSE,
		'v|version'  => \$::VERSION,))
	{

		&mknimimage_usage($callback);
        return 0;
	}

	# display the usage if -h or --help is specified
    if ($::HELP) {
        &mknimimage_usage($callback);
        return 0;
    }

	# display the version statement if -v or --verison is specified
    if ($::VERSION)
    {
		my $version=xCAT::Utils->Version();
        my $rsp;
        push @{$rsp->{data}}, "mknimimage $version\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
        return 0;
    }

	# the type is standalone by default
	if (!$::NIMTYPE) {
		$::NIMTYPE = "standalone";
	}

	# the NIM method is rte by default
	if (($::NIMTYPE eq "standalone") && !$::METHOD) {
		$::METHOD = "rte";
	}

	#
    # process @ARGV
    #

	# the first arg should be a noderange - the other should be attr=val
    #  - put attr=val operands in %::attrres hash
    while (my $a = shift(@ARGV))
    {
        if (!($a =~ /=/))
        {
			$::image_name = $a;
			chomp $::image_name;
        }
        else
        {
            # if it has an "=" sign its an attr=val - we hope
			# attr must be a NIM resource type and val must be a resource name
            my ($attr, $value) = $a =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;
            if (!defined($attr) || !defined($value))
            {
                my $rsp;
                $rsp->{data}->[0] = "Incorrect \'attr=val\' pair - $a\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 3;
            }
            # put attr=val in hash
			$::attrres{$attr} = $value;
        }
    }

	if ( ($::NIMTYPE eq "standalone") && $::OSIMAGE) {
		my $rsp;
		push @{$rsp->{data}}, "The \'-i\' option is only valid for diskless and dataless nodes.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		&mknimimage_usage($callback);
        return 1;
	}

	#
	#  Install/config NIM master if needed
	#
	# check for master file set
	my $lsnimcmd = "/usr/sbin/lsnim -l >/dev/null 2>&1";
	my $out = xCAT::Utils->runcmd("$lsnimcmd", -1);
	if ($::RUNCMD_RC  != 0) {
# TODO - check for bos.sysmgt.nim.client first?
		my $rsp;
        push @{$rsp->{data}}, "Configuring NIM.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);

		# if its not installed then run
		#   - takes 21 sec even when already configured
#  TODO - add location (opt_l) - so all res go in same place!
		my $nimcmd = "nim_master_setup -a mk_resource=no -a device=$::opt_s";
		if ($::VERBOSE) {
            my $rsp;
            push @{$rsp->{data}}, "Running: \'$nimcmd\'\n";
            xCAT::MsgUtils->message("I", $rsp, $callback);
        }
		my $nimout = xCAT::Utils->runcmd("$nimcmd", -1);
		if ($::RUNCMD_RC  != 0) {
			my $rsp;
			push @{$rsp->{data}}, "Could not install and configure NIM.\n";
			if ($::VERBOSE) {
                push @{$rsp->{data}}, "$nimout";
            }
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
	}

	#
	# see if the image_name (osimage) provided is already defined
	#
	my @deflist = xCAT::DBobjUtils->getObjectsOfType("osimage");
	if (grep(/^$::image_name$/, @deflist)) {
		if ($::FORCE) {
			# remove the existing osimage def and continue
			my %objhash;
			$objhash{$::image_name} = "osimage";
			if (xCAT::DBobjUtils->rmobjdefs(\%objhash) != 0) {
				my $rsp;
				push @{$rsp->{data}}, "Could not remove the existing xCAT definition for \'$::image_name\'.\n";
				xCAT::MsgUtils->message("E", $rsp, $::callback);
			}
		} else {
			my $rsp;
			push @{$rsp->{data}}, "The osimage definition \'$::image_name\' already exists.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
	}

	#
    #  Get a list of the all defined resources
    #
    my $cmd = qq~/usr/sbin/lsnim -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
    @::nimresources = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get NIM resource definitions.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	#
	#  Handle diskless, rte, & mksysb 
	#

	if ( ($::NIMTYPE eq "diskless") | ($::NIMTYPE eq "dataless") ) {

		# get the xCAT image definition if provided
    	if ($::opt_i) {
        	my %objtype;
			my $currentimage=$::opt_i;

			# get the image def
        	$objtype{$::opt_i} = 'osimage';

			%::imagedef = xCAT::DBobjUtils->getobjdefs(\%objtype,$callback);
			if (!defined(%::imagedef))
			{
				my $rsp;
				push @{$rsp->{data}}, "Could not get xCAT image definition.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return 1;
			}
		}

		# must have a source and a name
		if (!($::opt_s || $::opt_i) || !defined($::image_name) ) {
			my $rsp;
			push @{$rsp->{data}}, "The image name and either the -s or -i option are required.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			&mknimimage_usage($callback);
			return 1;
		}

		#
		# get lpp_source
		#
		$lpp_source_name = &mk_lpp_source($callback);
		chomp $lpp_source_name;
		$newres{lpp_source} = $lpp_source_name;
		if ( !defined($lpp_source_name)) {
			# error
			my $rsp;
            push @{$rsp->{data}}, "Could not create lpp_source definition.\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
		}

		#
		# spot resource
		#

		$spot_name=&mk_spot($lpp_source_name, $callback);
		chomp $spot_name;
		$newres{spot} = $spot_name;
		if ( !defined($spot_name)) {
			my $rsp;
            push @{$rsp->{data}}, "Could not create spot definition.\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
		}

		#
		#  Identify or create the rest of the resources for this diskless image
		#
		# 	- required - root, dump, paging, 
		#  

		#
		# root res
		#
		my $root_name;
		if ( $::attrres{root} ) {

        	# if provided on cmd line then use it
        	$root_name=$::attrres{root};

		} elsif ($::opt_i) {

# TODO - this logic looks wrong - may have an image def but if
#   no root then we still want to make one

			# if one is provided in osimage use it    
			if ($::imagedef{$::opt_i}{root}) {
				$root_name=$::imagedef{$::opt_i}{root};
			}

    	} else {

			# may need to create new one

			# use naming convention
			if ($::SHAREDROOT) {
                $root_name=$::image_name . "_shared_root";
            } else {
                $root_name=$::image_name . "_root";
            }
            chomp $root_name;

			# see if it's already defined
        	if (grep(/^$root_name$/, @::nimresources)) {
				my $rsp;
				push @{$rsp->{data}}, "Using existing root resource named \'$root_name\'.\n";
				xCAT::MsgUtils->message("I", $rsp, $callback);
        	} else {
				# it doesn't exist so create it

				my $type;
                if ($::SHAREDROOT) {
                    $type="shared_root";
                } else {
                    $type="root";
                }
				if (&mknimres($root_name, $type, $callback, $::opt_l, $spot_name) != 0) {
					my $rsp;
					push @{$rsp->{data}}, "Could not create a NIM definition for \'$root_name\'.\n";
					xCAT::MsgUtils->message("E", $rsp, $callback);
					return 1;
				}
			}
		} # end root res
		chomp $root_name;
		if ($::SHAREDROOT) {
            $newres{shared_root}= $root_name;
        } else {
            $newres{root} = $root_name;
        }

		#
		# dump res
		#  - dump is optional with new AIX versions
		#
		my $dodumpold=0;
		my $vrmf = xCAT::Utils->get_OS_VRMF();
		if (defined($vrmf)) {
			if (xCAT::Utils->testversion($vrmf, "<", "6.1.4.0")) {
					$dodumpold=1;
			}
		}

		if ($dodumpold) {

			my $dump_name;
			if ( $::attrres{dump} ) {

        		# if provided then use it
        		$dump_name=$::attrres{dump};

			} elsif ($::opt_i) {

        		# if one is provided in osimage 
        		if ($::imagedef{$::opt_i}{dump}) {
            		$dump_name=$::imagedef{$::opt_i}{dump};
        		}

    		} else {

				# may need to create new one
				# all use the same dump res unless another is specified
				$dump_name= $::image_name . "_dump";
				# see if it's already defined
        		if (grep(/^$dump_name$/, @::nimresources)) {
					my $rsp;
					push @{$rsp->{data}}, "Using existing dump resource named \'$dump_name\'.\n";
					xCAT::MsgUtils->message("I", $rsp, $callback);
        		} else {
					# create it
					my $type="dump";
					if (&mknimres($dump_name, $type, $callback, $::opt_l) != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not create a NIM definition for \'$dump_name\'.\n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
						return 1;
					}
				}
			} # end dump res
			chomp $dump_name;
        	$newres{dump} = $dump_name;
		} # end dodump old

		#
		# paging res
		#
		my $paging_name;
		if ( $::attrres{paging} ) {

        	# if provided then use it
        	$paging_name=$::attrres{paging};

		} elsif ($::opt_i) {

        	# if one is provided in osimage and we don't want a new one
        	if ($::imagedef{$::opt_i}{paging}) {
            	$paging_name=$::imagedef{$::opt_i}{paging};
        	}

    	} else {
			# create it
			# only if type diskless
			my $nimtype;
			if ($::NIMTYPE) {
				$nimtype = $::NIMTYPE;
			} else {
				$nimtype = "diskless";
			}
			chomp $nimtype;
		
			if ($nimtype eq "diskless" ) {

				$paging_name= $::image_name . "_paging";

				# see if it's already defined
        		if (grep(/^$paging_name$/, @::nimresources)) {
					my $rsp;
					push @{$rsp->{data}}, "Using existing paging resource named \'$paging_name\'.\n";
					xCAT::MsgUtils->message("I", $rsp, $callback);
        		} else {
					# it doesn't exist so create it
					my $type="paging";
					if (&mknimres($paging_name, $type, $callback, $::opt_l) != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not create a NIM definition for \'$paging_name\'.\n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
						return 1;
					}
				}
			}
		} # end paging res
		chomp $paging_name;
        $newres{paging} = $paging_name;

		#
		# end diskless section 
		#

	} elsif ( $::NIMTYPE eq "standalone") {

		# includes rte & mksysb methods

		#
        # create bosinst_data
		#
		$bosinst_data_name = &mk_bosinst_data($callback);
        chomp $bosinst_data_name;
        $newres{bosinst_data} = $bosinst_data_name;
        if ( !defined($bosinst_data_name)) {
			my $rsp;
            push @{$rsp->{data}}, "Could not create bosinst_data definition.\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }

		if ($::METHOD eq "rte" ) {

			# need lpp_source, spot & bosinst_data
			# optionally resolv_conf
			# user can specify others

			# must have a source and a name
			if (!($::opt_s) || !defined($::image_name) ) {
				my $rsp;
				push @{$rsp->{data}}, "The image name and -s option are required.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				&mknimimage_usage($callback);
				return 1;
			}

			#
			# get lpp_source
			#
			$lpp_source_name = &mk_lpp_source($callback);
			chomp $lpp_source_name;
			$newres{lpp_source} = $lpp_source_name;
			if ( !defined($lpp_source_name)) {
				my $rsp;
                push @{$rsp->{data}}, "Could not create lpp_source definition.\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
			}

		} elsif ($::METHOD eq "mksysb" ) {

			# need mksysb bosinst_data
			# user provides SPOT
			#  TODO - create SPOT from mksysb
            # user can specify others
			#
			# get mksysb resource
			#
			$mksysb_name=&mk_mksysb($callback);
            chomp $mksysb_name;
            $newres{mksysb} = $mksysb_name;
            if ( !defined($mksysb_name)) {
				my $rsp;
				push @{$rsp->{data}}, "Could not create mksysb definition.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return 1;
            }
		} 
		#
		# get spot resource
		#
		$spot_name=&mk_spot($lpp_source_name, $callback);
		chomp $spot_name;
		$newres{spot} = $spot_name;
		if ( !defined($spot_name)) {
			my $rsp;
			push @{$rsp->{data}}, "Could not create spot definition.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}

		#
		# create resolv_conf
		#
        my $resolv_conf_name = &mk_resolv_conf($callback);
		if (defined($resolv_conf_name)) {
        	chomp $resolv_conf_name;
        	$newres{resolv_conf} = $resolv_conf_name;
        }
	}

	#
	# Put together the osimage def information
	#
	$osimagedef{$::image_name}{objtype}="osimage";
    $osimagedef{$::image_name}{imagetype}="NIM";
    $osimagedef{$::image_name}{osname}="AIX";
    $osimagedef{$::image_name}{nimtype}=$::NIMTYPE;
	if ($::METHOD) {
		$osimagedef{$::image_name}{nimmethod}=$::METHOD;
	}

	#
    # get resources from the original osimage if provided
    #
    if ($::opt_i) {

        foreach my $type (keys %{$::imagedef{$::opt_i}}) {
            # could be comma list!!
            my $include = 1;
            my @reslist = split(/,/, $::imagedef{$::opt_i}{$type});
            foreach my $res (@reslist) {
                if (!grep(/^$res$/, @::nimresources)) {
                    my $include = 0;
                    last;
                }
            }

            if ($include) {
                $osimagedef{$::image_name}{$type}=$::imagedef{$::opt_i}{$type};
            }
        }
    }

	if (defined(%newres)) {

		# overlay/add the resources defined above
		foreach my $type (keys %newres) {
			$osimagedef{$::image_name}{$type}=$newres{$type};
		}
	}

	#
	# overwrite with anything provided on the command line
	#
	if (defined(%::attrres)) {

        # add overlay/any additional from the cmd line if provided
        foreach my $type (keys %::attrres) {
            # could be comma list!!
            my $include = 1;
            my @reslist = split(/,/, $::attrres{$type});
            foreach my $res (@reslist) {
                if (!grep(/^$res$/, @::nimresources)) {
                    my $include = 0;
                    last;
                }
            }

            if ($include) {
                $osimagedef{$::image_name}{$type}=$::attrres{$type};
            }
        }
    }

	# create the osimage def
	if (xCAT::DBobjUtils->setobjdefs(\%osimagedef) != 0)
    {
        my $rsp;
        $rsp->{data}->[0] = "Could not create xCAT osimage definition.\n";
		xCAT::MsgUtils->message("E", $rsp, $::callback);
        return 1;
    }

	#
	# Output results
	#
	#
	my $rsp;
	push @{$rsp->{data}}, "The following xCAT osimage definition was created. Use the xCAT lsdef command \nto view the xCAT definition and the AIX lsnim command to view the individual \nNIM resources that are included in this definition.";

	push @{$rsp->{data}}, "\nObject name: $::image_name";

	foreach my $attr (sort(keys %{$osimagedef{$::image_name}}))
	{
		if ($attr eq 'objtype') {
			next;
		}
		push @{$rsp->{data}}, "\t$attr=$osimagedef{$::image_name}{$attr}";
	}
	xCAT::MsgUtils->message("I", $rsp, $callback);

	return 0;

} # end mknimimage

#----------------------------------------------------------------------------

=head3   mk_lpp_source

        Create a NIM   resource.

        Returns:
                lpp_source name -ok
                undef - error
=cut

#-----------------------------------------------------------------------------
sub mk_lpp_source
{
	my $callback = shift;

	my @lppresources;
	my $lppsrcname;

	#
    #  Get a list of the defined lpp_source resources
    #
    my $cmd = qq~/usr/sbin/lsnim -t lpp_source | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
    @lppresources = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get NIM lpp_source definitions.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return undef;
    }

	#
	# get an lpp_source resource to use
	#
	if ( $::attrres{lpp_source} ) { 

		# if lpp_source provided then use it
		$lppsrcname=$::attrres{lpp_source};

	} elsif ($::opt_i) { 

		# if we have lpp_source name in osimage def then use that
		if ($::imagedef{$::opt_i}{lpp_source}) {
			$lppsrcname=$::imagedef{$::opt_i}{lpp_source};
		} else {
			my $rsp;
			push @{$rsp->{data}}, "The $::opt_i image definition did not contain a value for lpp_source.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return undef;
		}

	} elsif ($::opt_s) { 

		# if this isn't a dir and it is an 
		#existing lpp_source then use it
		if ( !(-d $::opt_s) ) {
            if ((grep(/^$::opt_s$/, @lppresources))) {
                # if an lpp_source was provided then use it
                return $::opt_s;

            }
        }

		# if source is provided we may need to create a new lpp_source

		#   make a name using the convention and check if it already exists
		$lppsrcname= $::image_name . "_lpp_source";

		if (grep(/^$lppsrcname$/, @lppresources)) {
			my $rsp;
			push @{$rsp->{data}}, "Using the existing lpp_source named \'$lppsrcname\'\n";
			xCAT::MsgUtils->message("I", $rsp, $callback);
		} else {

			# create a new one

			# the source could be a directory or an existing 
			#	lpp_source resource
			if ( !(-e $::opt_s) ) {
				# if it's not a directory then is it the name of 
				#	an existing lpp_source?
				if (!(grep(/^$::opt_s$/, @lppresources))) {
					my $rsp;
					push @{$rsp->{data}}, "\'$::opt_s\' is not a source directory or the name of a NIM lpp_source resource.\n";
               		xCAT::MsgUtils->message("E", $rsp, $callback);
               		&mknimimage_usage($callback);
               		return undef;
				}
			}
			
			my $loc;
			if ($::opt_l) {
				$loc = "$::opt_l/lpp_source/$lppsrcname";
			} else {
				$loc = "/install/nim/lpp_source/$lppsrcname";
			}
			
			# create resource location 
            my $cmd = "/usr/bin/mkdir -p $loc";
            my $output = xCAT::Utils->runcmd("$cmd", -1);
            if ($::RUNCMD_RC  != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Could not create $loc.\n";
                if ($::VERBOSE) {
                    push @{$rsp->{data}}, "$output\n";
                }
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return undef;
            }

			# check the file system space needed ????
			#  about 1500 MB for a basic lpp_source???
			my $lppsize = 1500;
            if (&chkFSspace($loc, $lppsize, $callback) != 0) {
				return undef;
            }

			# build an lpp_source 
			my $rsp;
			push @{$rsp->{data}}, "Creating a NIM lpp_source resource called \'$lppsrcname\'.  This could take a while.\n";
			xCAT::MsgUtils->message("I", $rsp, $callback);

			# make cmd
			my $lpp_cmd = "/usr/sbin/nim -Fo define -t lpp_source -a server=master ";

			# set multi_volume to yes just in case /dev/cd0 is provided
			$lpp_cmd .= "-a multi_volume=yes ";

			# where to put it - the default is /install
			$lpp_cmd .= "-a location=$loc ";

			$lpp_cmd .= "-a source=$::opt_s $lppsrcname";

			if ($::VERBOSE) {
				my $rsp;
				push @{$rsp->{data}}, "Running: \'$lpp_cmd\'\n";
				xCAT::MsgUtils->message("I", $rsp, $callback);
			}

			my $output = xCAT::Utils->runcmd("$lpp_cmd", -1);
   			if ($::RUNCMD_RC  != 0)
   			{
       			my $rsp;
       			push @{$rsp->{data}}, "Could not run command \'$lpp_cmd\'. (rc = $::RUNCMD_RC)\n";
       			xCAT::MsgUtils->message("E", $rsp, $callback);
   				return undef;
   			}
		}
	} else {
		my $rsp;
		push @{$rsp->{data}}, "Could not get an lpp_source resource for this diskless image.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return undef;
	} 

	return $lppsrcname;
}

#----------------------------------------------------------------------------

=head3   mk_spot

        Create a NIM   resource.

        Returns:
               OK - spot name
               error - undef
=cut

#-----------------------------------------------------------------------------
sub mk_spot
{
	my $lppsrcname = shift;
    my $callback = shift;

	my $spot_name;
	my $currentimage;

		if ( $::attrres{spot} ) { 

			# if spot provided then use it
        	$spot_name=$::attrres{spot};

    	} elsif ($::opt_i) {
			# copy the spot named in the osimage def

			# use the image name for the new SPOT/COSI name
			$spot_name=$::image_name;
	
			if ($::imagedef{$::opt_i}{spot}) {
				# a spot was provided as a source so copy it to create a new one 
				my $cpcosi_cmd = "/usr/sbin/cpcosi ";

				# name of cosi to copy
				$currentimage=$::imagedef{$::opt_i}{spot};
				chomp $currentimage;
            	$cpcosi_cmd .= "-c $currentimage ";

				# do we want verbose output?
				if ($::VERBOSE) {
					$cpcosi_cmd .= "-v ";
				}

				# where to put it - the default is /install
				if ($::opt_l) {
					$cpcosi_cmd .= "-l $::opt_l/spot ";
				} else {
					$cpcosi_cmd .= "-l /install/nim/spot  ";
				}

            	$cpcosi_cmd .= "$spot_name  2>&1";

				# run the cmd
				my $rsp;
				push @{$rsp->{data}}, "Creating a NIM SPOT resource. This could take a while.\n";
				xCAT::MsgUtils->message("I", $rsp, $callback);

				if ($::VERBOSE) {
					my $rsp;
					push @{$rsp->{data}}, "Running: \'$cpcosi_cmd\'\n";
					xCAT::MsgUtils->message("I", $rsp, $callback);
				}
				my $output = xCAT::Utils->runcmd("$cpcosi_cmd", -1);
				if ($::RUNCMD_RC  != 0)
				{
					my $rsp;
					push @{$rsp->{data}}, "Could not create a NIM definition for \'$spot_name\'.\n";
					xCAT::MsgUtils->message("E", $rsp, $callback);
					return undef;
				}
			} else {
				my $rsp;
				push @{$rsp->{data}}, "The $::opt_i image definition did not contain a value for a SPOT resource.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
            	return undef;
        	}

		} else {

			# create a new spot from the lpp_source 

			# use the image name for the new SPOT/COSI name
			$spot_name=$::image_name;

        	if (grep(/^$spot_name$/, @::nimresources)) {
            	my $rsp;
            	push @{$rsp->{data}}, "Using the existing SPOT named \'$spot_name\'.\n";
            	xCAT::MsgUtils->message("I", $rsp, $callback);
        	} else {

				# Create the SPOT/COSI
				my $cmd = "/usr/sbin/nim -o define -t spot -a server=master ";

				# source of images
				$cmd .= "-a source=$lppsrcname ";

				# where to put it - the default is /install
				my $loc;
				if ($::opt_l) {
					$cmd .= "-a location=$::opt_l/spot ";
					$loc = "$::opt_l/spot";
				} else {
					$cmd .= "-a location=/install/nim/spot  ";
					$loc = "/install/nim/spot";
				}

				# create resource location
                my $mkdircmd = "/usr/bin/mkdir -p $loc";
                my $output = xCAT::Utils->runcmd("$mkdircmd", -1);
                if ($::RUNCMD_RC  != 0) {
                    my $rsp;
                    push @{$rsp->{data}}, "Could not create $loc.\n";
                    if ($::VERBOSE) {
                        push @{$rsp->{data}}, "$output\n";
                    }
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    return undef;
                }

				# check the file system space needed 
				#	500 MB for spot ?? 64MB for tftpboot???
				my $spotsize = 500;
                if (&chkFSspace($loc, $spotsize, $callback) != 0) {
                	# error
					return undef;
                }

				$loc = "/tftpboot";
				# create resource location
                my $mkdircmd = "/usr/bin/mkdir -p $loc";
                my $output = xCAT::Utils->runcmd("$mkdircmd", -1);
                if ($::RUNCMD_RC  != 0) {
                    my $rsp;
                    push @{$rsp->{data}}, "Could not create $loc.\n";
                    if ($::VERBOSE) {
                        push @{$rsp->{data}}, "$output\n";
                    }
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                    return undef;
                }
				my $tftpsize = 64;
				if (&chkFSspace($loc, $tftpsize, $callback) != 0) {
                    # error
					return undef;
                }

				$cmd .= "$spot_name  2>&1";
				# run the cmd
				my $rsp;
				push @{$rsp->{data}}, "Creating a NIM SPOT resource. This could take a while.\n";
				xCAT::MsgUtils->message("I", $rsp, $callback);

				my $output = xCAT::Utils->runcmd("$cmd", -1);
				if ($::RUNCMD_RC  != 0)
				{
					my $rsp;
					push @{$rsp->{data}}, "Could not create a NIM definition for \'$spot_name\'.\n";
					xCAT::MsgUtils->message("E", $rsp, $callback);
					return undef;
				}
			} # end - if spot doesn't exist
		}

    return $spot_name;
}


#----------------------------------------------------------------------------

=head3   mk_bosinst_data

        Create a NIM   resource.

        Returns:
                0 - OK
                1 - error
=cut

#-----------------------------------------------------------------------------
sub mk_bosinst_data
{
    my $callback = shift;

	my $bosinst_data_name = $::image_name . "_bosinst_data";

    if ( $::attrres{bosinst_data} ) {

        # if provided then use it
        $bosinst_data_name=$::attrres{bosinst_data};

	} elsif ($::opt_i) {

        # if one is provided in osimage and we don't want a new one
        if ($::imagedef{$::opt_i}{bosinst_data}) {
            $bosinst_data_name=$::imagedef{$::opt_i}{bosinst_data};
        }

    } else {

		# see if it's already defined
		if (grep(/^$bosinst_data_name$/, @::nimresources)) {
			my $rsp;
			push @{$rsp->{data}}, "Using existing bosinst_data resource named \'$bosinst_data_name\'.\n";
			xCAT::MsgUtils->message("I", $rsp, $callback);
		} else {

			my $loc;
			if ($::opt_l) {
				$loc = "$::opt_l/bosinst_data";
			} else {
				$loc = "/install/nim/bosinst_data";
			}

			my $cmd = "mkdir -p $loc";

           	my $output = xCAT::Utils->runcmd("$cmd", -1);
           	if ($::RUNCMD_RC  != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Could not create a NIM definition for \'$bosinst_data_name\'.\n";
				if ($::VERBOSE) {
                    push @{$rsp->{data}}, "$output\n";
                }
                xCAT::MsgUtils->message("E", $rsp, $callback);
				return undef;
            }

			# copy/modify the template supplied by NIM
			my $sedcmd = "/usr/bin/sed 's/CONSOLE = .*/CONSOLE = Default/; s/INSTALL_METHOD = .*/INSTALL_METHOD = overwrite/; s/PROMPT = .*/PROMPT = no/; s/EXISTING_SYSTEM_OVERWRITE = .*/EXISTING_SYSTEM_OVERWRITE = yes/; s/RECOVER_DEVICES = .*/RECOVER_DEVICES = no/; s/ACCEPT_LICENSES = .*/ACCEPT_LICENSES = yes/; s/DESKTOP = .*/DESKTOP = NONE/' /usr/lpp/bosinst/bosinst.template >$loc/$bosinst_data_name";

			my $output = xCAT::Utils->runcmd("$sedcmd", -1);
			if ($::RUNCMD_RC  != 0) {
				my $rsp;
				push @{$rsp->{data}}, "Could not create bosinst_data file.\n";
				if ($::VERBOSE) {
					push @{$rsp->{data}}, "$output\n";
				}
				xCAT::MsgUtils->message("E", $rsp, $callback);
                return undef;
			}

			# define the new bosinst_data resource
			my $cmd = "/usr/sbin/nim -o define -t bosinst_data -a server=master ";
			$cmd .= "-a location=$loc/$bosinst_data_name  ";
			$cmd .= "$bosinst_data_name  2>&1";

			if ($::VERBOSE) {
                my $rsp;
                push @{$rsp->{data}}, "Running: \'$cmd\'\n";
                xCAT::MsgUtils->message("I", $rsp, $callback);
            }

			my $output = xCAT::Utils->runcmd("$cmd", -1);
			if ($::RUNCMD_RC  != 0) {
				my $rsp;
				push @{$rsp->{data}}, "Could not create a NIM definition for \'$bosinst_data_name\'.\n";
				if ($::VERBOSE) {
                    push @{$rsp->{data}}, "$output\n";
                }
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return undef;
			}
		}
	} 

    return $bosinst_data_name;
}

#----------------------------------------------------------------------------

=head3   mk_resolv_conf_file

        Create a resolv.conf file from data in xCAT site table.

		Only if the node "domain" & "nameservers" attrs are set!

        Returns:
                0 - OK
                1 - error
=cut

#-----------------------------------------------------------------------------
sub mk_resolv_conf_file
{
	my $callback = shift;
	my $loc = shift;

	my $fullname = "$loc/resolv.conf";

	# check site table - get domain, nameservers attr
	my $sitetab = xCAT::Table->new('site');
    my ($tmp) = $sitetab->getAttribs( { 'key' => 'domain' }, 'value' );
    my $domain = $tmp->{value};
    my ($tmp2) = $sitetab->getAttribs( { 'key' => 'nameservers' }, 'value' );
    my $nameservers = $tmp2->{value};
	$sitetab->close;

	# if set then create file
	if ($domain && $nameservers) {
		# fullname is something like 
		#	/install/nim/resolv_conf/610img_resolv_conf/resolv.conf

		my $mkcmd = "/usr/bin/mkdir -p $loc";
		my $output = xCAT::Utils->runcmd("$mkcmd", -1);
		if ($::RUNCMD_RC  != 0) {
			my $rsp;
			push @{$rsp->{data}}, "Could not create $loc.\n";
			if ($::VERBOSE) {
				push @{$rsp->{data}}, "$output\n";
			}
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return undef;
		}

		unless (open(RSCNF, ">$fullname")) {
            my $rsp;
            push @{$rsp->{data}}, "Could not open $fullname.\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
		
		# add the domain
		print RSCNF "search $domain\n";

		# add nameservers
		foreach (split /,/,$nameservers) {
			print RSCNF "nameserver $_\n";
		}
		close (RSCNF);
	} else {
        return 1;
    }
	return 0;
}

#----------------------------------------------------------------------------

=head3   mk_resolv_conf

        Create a NIM   resource.

		Only if the node "domain" & "nameservers" attrs are set!  If
		not set assume user does not want resolv.conf file

        Returns:
                0 - OK
                1 - error
=cut

#-----------------------------------------------------------------------------
sub mk_resolv_conf
{
    my $callback = shift;

	my $resolv_conf_name = $::image_name . "_resolv_conf";

    if ( $::attrres{resolv_conf} ) {

        # if provided on cmd line then use it
        $resolv_conf_name=$::attrres{resolv_conf};

	} elsif ($::opt_i) {

        # if one is provided in osimage def - use that
        if ($::imagedef{$::opt_i}{resolv_conf}) {
            $resolv_conf_name=$::imagedef{$::opt_i}{resolv_conf};
        }

    } else {

		# we may need to create a new one
		# check site table - get domain, nameservers attr
    	my $sitetab = xCAT::Table->new('site');
    	my ($tmp) = $sitetab->getAttribs( { 'key' => 'domain' }, 'value' );
    	my $domain = $tmp->{value};
    	my ($tmp2) = $sitetab->getAttribs( { 'key' => 'nameservers' }, 'value' );
    	my $nameservers = $tmp2->{value};
    	$sitetab->close;
 
    	# if set then we want a resolv_conf file
    	if (defined($domain) && defined($nameservers)) {
			# see if it's already defined
        	if (grep(/^$resolv_conf_name$/, @::nimresources)) {
            	my $rsp;
            	push @{$rsp->{data}}, "Using existing resolv_conf resource named \'$resolv_conf_name\'.\n";
            	xCAT::MsgUtils->message("I", $rsp, $callback);
        	} else {

				my $fileloc;
				my $loc;
				if ($::opt_l) {
					$loc = "$::opt_l/resolv_conf/$resolv_conf_name";
				} else {
					$loc = "/install/nim/resolv_conf/$resolv_conf_name";
				}

				$fileloc = "$loc/resolv.conf";

				# create the resolv.conf file based on the domain & nameservers
				#	attrs in the xCAT site table
				my $rc = &mk_resolv_conf_file($callback, $loc);
				if ($rc != 0) {
            		return undef;
        		}
				# define the new resolv_conf resource
				my $cmd = "/usr/sbin/nim -o define -t resolv_conf -a server=master ";
				$cmd .= "-a location=$fileloc ";
				$cmd .= "$resolv_conf_name  2>&1";

				if ($::VERBOSE) {
					my $rsp;
					push @{$rsp->{data}}, "Running: \'$cmd\'\n";
					xCAT::MsgUtils->message("I", $rsp, $callback);
				}

				my $output = xCAT::Utils->runcmd("$cmd", -1);
				if ($::RUNCMD_RC  != 0) {
					my $rsp;
					push @{$rsp->{data}}, "Could not create a NIM definition for \'$resolv_conf_name\'.\n";
					xCAT::MsgUtils->message("E", $rsp, $callback);
					return undef;
				}
			}
		} else {
			return undef;
		}
	} # end resolv_conf res

    return $resolv_conf_name;
}

#----------------------------------------------------------------------------

=head3   mk_mksysb

        Create a NIM   resource.

        Returns:
                0 - OK
                1 - error
=cut

#-----------------------------------------------------------------------------
sub mk_mksysb
{
    my $callback = shift;

	my $mksysb_name = $::image_name . "_mksysb";

	if ( $::attrres{mksysb} ) {

        # if provided on cmd line then use it
        $mksysb_name=$::attrres{mksysb};

    } else {
		# see if it's already defined
        if (grep(/^$mksysb_name$/, @::nimresources)) {
            my $rsp;
            push @{$rsp->{data}}, "Using existing mksysb resource named \'$mksysb_name\'.\n";
            xCAT::MsgUtils->message("I", $rsp, $callback);
        } else {

			# create the mksysb definition

			if ($::MKSYSBNODE) {

				my $loc;
            	if ($::opt_l) {
                	$loc = "$::opt_l/mksysb/$::image_name";
            	} else {
					$loc = "/install/nim/mksysb/$::image_name";
            	}

				# create resource location for mksysb image
				my $cmd = "/usr/bin/mkdir -p $loc";
				my $output = xCAT::Utils->runcmd("$cmd", -1);
            	if ($::RUNCMD_RC  != 0) {
                	my $rsp;
                	push @{$rsp->{data}}, "Could not create $loc.\n";
                	if ($::VERBOSE) {
                    	push @{$rsp->{data}}, "$output\n";
                	}
                	xCAT::MsgUtils->message("E", $rsp, $callback);
                	return undef;
            	}

				# check the file system space needed
				# about 1800 MB for a mksysb image???
				my $sysbsize = 1800;
				if (&chkFSspace($loc, $sysbsize, $callback) != 0) {
					# error
					return undef;
				}

				my $rsp;
				push @{$rsp->{data}}, "Creating a NIM mksysb resource called \'$mksysb_name\'.  This could take a while.\n";
				xCAT::MsgUtils->message("I", $rsp, $callback);

				# create sys backup from remote node and define res
				my $location = "$loc/$mksysb_name";
				my $nimcmd = "/usr/sbin/nim -o define -t mksysb -a server=master -a location=$location -a mk_image=yes -a source=$::MKSYSBNODE $mksysb_name 2>&1";

				my $output = xCAT::Utils->runcmd("$nimcmd", -1);
            	if ($::RUNCMD_RC  != 0) {
                	my $rsp;
                	push @{$rsp->{data}}, "Could not define mksysb resource named \'$mksysb_name\'.\n";
                	if ($::VERBOSE) {
                    	push @{$rsp->{data}}, "$output\n";
                	}
                	xCAT::MsgUtils->message("E", $rsp, $callback);
                	return undef;
            	}

			} elsif ($::SYSB) {

				# def res with existing mksysb image
				my $mkcmd = "/usr/sbin/nim -o define -t mksysb -a server=master -a location=$::SYSB $mksysb_name 2>&1";

				if ($::VERBOSE) {
                    my $rsp;
                    push @{$rsp->{data}}, "Running: \'$mkcmd\'\n";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }

				my $output = xCAT::Utils->runcmd("$mkcmd", -1);
				if ($::RUNCMD_RC  != 0) {
					my $rsp;
					push @{$rsp->{data}}, "Could not define mksysb resource named \'$mksysb_name\'.\n";
					if ($::VERBOSE) {
						push @{$rsp->{data}}, "$output\n";
					}
					xCAT::MsgUtils->message("E", $rsp, $callback);
					return undef;
				}
			}
		}
	}

    return $mksysb_name;
}

#----------------------------------------------------------------------------

=head3   prermnimimage

        Preprocessing for the rmnimimage command.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:
        Error:
        Example:
        Comments:
=cut

#-----------------------------------------------------------------------------
sub prermnimimage
{
	my $callback = shift;

	if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
        &rmnimimage_usage($callback);
        return (1);
    }

	# parse the options
    Getopt::Long::Configure("no_pass_through");
    if(!GetOptions(
        'f|force'   => \$::FORCE,
        'h|help'    => \$::HELP,
        'verbose|V' => \$::VERBOSE,
        'v|version' => \$::VERSION,))
    {

        &rmnimimage_usage($callback);
        return (1);
    }

	 # display the usage if -h or --help is specified
    if ($::HELP) {
        &rmnimimage_usage($callback);
        return (2);
    }

    # display the version statement if -v or --verison is specified
    if ($::VERSION)
    {
        my $version=xCAT::Utils->Version();
        my $rsp;
        push @{$rsp->{data}}, "rmnimimage $version\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
        return (2);
    }

	my $image_name = shift @ARGV;

    # must have an image name
    if (!defined($image_name) ) {
        my $rsp;
        push @{$rsp->{data}}, "The xCAT osimage name is required.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        &rmnimimage_usage($callback);
        return (1);
    }

    # get the xCAT image definition
    my %imagedef;
    my %objtype;
    $objtype{$image_name} = 'osimage';
    %imagedef = xCAT::DBobjUtils->getobjdefs(\%objtype,$callback);
    if (!defined(%imagedef)) {
        my $rsp;
        push @{$rsp->{data}}, "Could not get xCAT image definition.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return (0);
    }

	#
    # remove the osimage def
    #
    my %objhash;
    $objhash{$image_name} = "osimage";

    if (xCAT::DBobjUtils->rmobjdefs(\%objhash) != 0) { 
        my $rsp;
        push @{$rsp->{data}}, "Could not remove the existing xCAT definition for \'$image_name\'.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
    } else {
        my $rsp;
        push @{$rsp->{data}}, "Removed the xCAT osimage definition \'$image_name\'.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }

	return (0, \%imagedef);
}

#----------------------------------------------------------------------------

=head3   rmnimimage

		Support for the rmnimimage command.

		Removes an AIX/NIM diskless image - referred to as a SPOT or COSI.

		Arguments:
		Returns:
				0 - OK
				1 - error
		Globals:

		Error:

		Example:

		Comments:
			rmnimimage [-V] [-f|--force] image_name
=cut

#-----------------------------------------------------------------------------
sub rmnimimage
{
	my $callback = shift;
	my $imaghash = shift;

	my %imagedef;
	if ($imaghash) {
		%imagedef = %{$imaghash};
	} else {
		return 0;
	}

	if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
		&rmnimimage_usage($callback);
        return 0;
    }	

    # parse the options
    Getopt::Long::Configure("no_pass_through");
    if(!GetOptions(
        'f|force'   => \$::FORCE,
        'h|help'    => \$::HELP,
        'verbose|V' => \$::VERBOSE,
        'v|version' => \$::VERSION,))
    {

        &rmnimimage_usage($callback);
        return 1;
    }

	my $image_name = shift @ARGV;

    # must have an image name
    if (!defined($image_name) ) {
        my $rsp;
        push @{$rsp->{data}}, "The xCAT osimage name is required.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        &rmnimimage_usage($callback);
        return 1;
    }

	#
	#  Get a list of the all the locally defined nim resources
	#
	my $cmd = qq~/usr/sbin/lsnim -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
	my @nimresources = ();
	@nimresources = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0)
	{
		my $rsp;
        push @{$rsp->{data}}, "Could not get NIM resource definitions.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
	}

	my $rsp;
	push @{$rsp->{data}}, "Removing NIM resource definitions. This could take a while!";
	xCAT::MsgUtils->message("I", $rsp, $callback);

	# foreach attr in the image def
	my $error;
	foreach my $attr (sort(keys %{$imagedef{$image_name}}))
    {
        if ($attr eq 'objtype') {
            next;
        }

		my $resname = $imagedef{$image_name}{$attr};
		# if it's a defined resource name we can try to remove it
		if ( ($resname)  && (grep(/^$resname$/, @nimresources))) {

			# is it allocated?
			my $alloc_count = &get_nim_attr_val($resname, "alloc_count", $callback);

			if ( defined($alloc_count) && ($alloc_count != 0) ){
				my $rsp;
				push @{$rsp->{data}}, "The resource named \'$resname\' is currently allocated. It will not be removed.\n";
				xCAT::MsgUtils->message("I", $rsp, $callback);
				next;
			}

			# try to remove it
			my $cmd = "nim -o remove $resname";

			my $output;
		    $output = xCAT::Utils->runcmd("$cmd", -1);
		    if ($::RUNCMD_RC  != 0)
       		{
				my $rsp;
				push @{$rsp->{data}}, "Could not remove the NIM resource definition \'$resname\'.\n";
				push @{$rsp->{data}}, "$output";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				$error++;
				next;
			} else {
				my $rsp;
				push @{$rsp->{data}}, "Removed the NIM resource named \'$resname\'.\n";
				xCAT::MsgUtils->message("I", $rsp, $callback);

			}
		}

	}

	if ($error) {
		my $rsp;
		push @{$rsp->{data}}, "One or more errors occurred when trying to remove the xCAT osimage definition \'$image_name\' and the related NIM resources.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	return 0;
}

#-------------------------------------------------------------------------

=head3   mkScriptRes

   Description
		- define NIM script resource if needed
   Arguments:    None.
   Return Codes: 0 - All was successful.
                 1 - An error occured.
=cut

#------------------------------------------------------------------------
sub mkScriptRes
{
	my $resname = shift;
	my $respath = shift;
	my $nimprime = shift;
	my $callback = shift;

    my ($defcmd, $output, $rc);
	my $cmd;

	if ( ($nimprime) && (!is_me($nimprime)) ) {
		# if the NIM primary is not the node we're running on
		$cmd = qq~xdsh $nimprime "/usr/sbin/lsnim -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
	} else {
		# assume we're running on the NIM primary
		$cmd = qq~/usr/sbin/lsnim -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
	}
    my @nimresources = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not get NIM resource definitions.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }
    if (!grep(/^$resname$/, @nimresources)) {

		if ( ($nimprime) && (!is_me($nimprime)) ) {
			$defcmd = qq~xdsh $nimprime "/usr/sbin/nim -o define -t script -a server=master -a location=$respath $resname 2>/dev/null"~;
		} else {
    		$defcmd = qq~/usr/sbin/nim -o define -t script -a server=master -a location=$respath $resname 2>/dev/null~;
		}

    	my $output = xCAT::Utils->runcmd("$defcmd", -1);
    	if ($::RUNCMD_RC != 0)
    	{
			if ($::VERBOSE) {
				my $rsp;
            	push @{$rsp->{data}}, "$output";
				xCAT::MsgUtils->message("E", $rsp, $callback);
        	}
        	return 1;
    	}
	}
    return 0;
}

#-------------------------------------------------------------------------

=head3   update_rhosts

   Description
         - add node entries to the /.rhosts file on the server
			- AIX only

   Arguments:    None.

   Return Codes: 0 - All was successful.
                 1 - An error occured.
=cut

#------------------------------------------------------------------------
sub update_rhosts 
{
	my $nodelist = shift;
	my $callback = shift;

	my $rhostname ="/.rhosts";
	my @addnodes;

	# make a list of node entries to add
	foreach my $node (@$nodelist) {

		# get the node IP for the file entry
		# TODO - need IPv6 update
		my $IP = inet_ntoa(inet_aton($node));
		chomp $IP;
		unless ($IP =~ /\d+\.\d+\.\d+\.\d+/)
		{
			my $rsp;
			push @{$rsp->{data}}, "Could not get valid IP address for node $node.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			next;
		}

		# is this node already in the file
		my $entry = "$IP root";
		#my $cmd = "cat $rhostname | grep '$IP root'";
		my $cmd = "cat $rhostname | grep $entry";
    	my @result = xCAT::Utils->runcmd("$cmd", -1);
    	if ($::RUNCMD_RC == 0)
    	{
        	# it's already there so next
        	next;
    	}
		push @addnodes, $entry;
	}

	if (defined(@addnodes)) {
		# add the new entries to the file
    	unless (open(RHOSTS, ">>$rhostname")) {
        	my $rsp;
        	push @{$rsp->{data}}, "Could not open $rhostname for appending.\n";
        	xCAT::MsgUtils->message("E", $rsp, $callback);
        	return 1;
    	}
		foreach (@addnodes) {
    		print RHOSTS $_ . "\n";
		}

    	close (RHOSTS);
	}
    return 0;
}

#-------------------------------------------------------------------------

=head3   update_inittab  
                                                                         
   Description:  This function updates the /etc/inittab file. 
                                                                         
   Arguments:    None.                                                   
                                                                         
   Return Codes: 0 - All was successful.                                 
                 1 - An error occured.                                   
=cut

#------------------------------------------------------------------------
sub update_inittab
{
	my $spot_loc = shift;
	my $callback = shift;
    my ($cmd, $rc, $entry);

	my $spotinittab = "$spot_loc/lpp/bos/inst_root/etc/inittab";

	my $entry = "xcat:2:wait:/opt/xcat/xcataixpost\n";

	# see if xcataixpost is already in the file
	my $cmd = "cat $spotinittab | grep xcataixpost";
	my @result = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC == 0)
    {
		# it's already there so return
		return 0;
    }

	unless (open(INITTAB, ">>$spotinittab")) {
		my $rsp;
		push @{$rsp->{data}}, "Could not open $spotinittab for appending.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	print INITTAB $entry;

	close (INITTAB);

	return 0;
}
#----------------------------------------------------------------------------

=head3  get_nim_attr_val

        Use the lsnim command to find the value of a resource attribute.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------
sub get_nim_attr_val 
{

	my $resname = shift;
	my $attrname = shift;
	my $callback = shift;
	my $nimprime = shift;

	my $cmd;
	if ( ($nimprime) && (!is_me($nimprime)) ) {
		# if the NIM primary is not the node we're running on
		$cmd = qq~xdsh $nimprime "/usr/sbin/lsnim -l $resname 2>/dev/null"~;
	} else {
		# assume we're running on the NIM primary
		$cmd = "/usr/sbin/lsnim -l $resname 2>/dev/null";
	}

	my @result = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
		my $rsp;
        push @{$rsp->{data}}, "Could not run lsnim command: \'$cmd\'.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	foreach (@result){
		my ($attr,$value) = split('=');
		chomp $attr;
		$attr =~ s/\s*//g;  # remove blanks
		chomp $value;
		$value =~ s/^\s*//;
		if ($attr eq $attrname) {
			return $value;
		}
	}
	return undef;
}


#----------------------------------------------------------------------------

=head3  get_res_loc

        Use the lsnim command to find the location of a spot resource.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:

        Error:

        Example:

        Comments:
=cut

#-----------------------------------------------------------------------------
sub get_res_loc {

	my $spotname = shift;
	my $callback = shift;

	my $cmd = "/usr/sbin/lsnim -l $spotname 2>/dev/null";

	my @result = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
		my $rsp;
        push @{$rsp->{data}}, "Could not run lsnim command: \'$cmd\'.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	foreach (@result){
		my ($attr,$value) = split('=');
		chomp $attr;
		$attr =~ s/\s*//g;  # remove blanks
		chomp $value;
		$value =~ s/\s*//g;  # remove blanks
		if ($attr eq 'location') {
			return $value;
		}
	}
	return undef;
}
#----------------------------------------------------------------------------

=head3  chkFSspace
	
	See if there is enough space in file systems. If not try to increase 
	the size.

        Arguments:
        Returns:
                0 - OK
                1 - error
=cut

#-----------------------------------------------------------------------------
sub chkFSspace {
	my $location = shift;
    my $size = shift;
    my $callback = shift;

	# get free space
    # ex. 1971.06 (Free MB)
    my $dfcmd = qq~/usr/bin/df -m $location | /usr/bin/awk '(NR==2){print \$3":"\$7}'~;

    my $output;
    $output = xCAT::Utils->runcmd("$dfcmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not run: \'$dfcmd\'\n";
        if ($::VERBOSE) {
            push @{$rsp->{data}}, "$output";
        }
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	my ($free_space, $FSname) = split(':', $output);

	#
    #  see if we need to increase the size of the fs
    #
	my $space_needed;
    if ( $size >= $free_space) {

		$space_needed = int ($size - $free_space);
		my $addsize = $space_needed+10;
		my $sizeattr = "-a size=+$addsize" . "M";
        my $chcmd = "/usr/sbin/chfs $sizeattr $FSname";

        my $output;
        $output = xCAT::Utils->runcmd("$chcmd", -1);
        if ($::RUNCMD_RC  != 0)
        {
            my $rsp;
            push @{$rsp->{data}}, "Could not increase file system size for \'$FSname\'. Additonal $addsize MB is needed.\n";
            if ($::VERBOSE) {
                push @{$rsp->{data}}, "$output";
            }
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
	}
	return 0;
}

#----------------------------------------------------------------------------

=head3  enoughspace

        See if the NIM root resource has enough space to initialize 
			another node.  If not try to add space to the FS.

        Arguments:
        Returns:
                0 - OK
                1 - error
=cut

#-----------------------------------------------------------------------------
sub enoughspace {

	my $spotname = shift;
	my $rootname = shift;
	my $pagingsize = shift;
    my $callback = shift;

	#
	#  how much space do we need for a root dir?
	#

    #  Get the SPOT location ( path to ../usr)
    my $spot_loc = &get_res_loc($spotname, $callback);
    if (!defined($spot_loc) ) {
        my $rsp;
        push @{$rsp->{data}}, "Could not get the location of the SPOT/COSI named $spot_loc.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	# get the inst_root location
	# ex. /install/nim/spot/61cosi/61cosi/usr/lpp/bos/inst_root
	my $spot_root_loc = "$spot_loc/lpp/bos/inst_root";

	# get the size of the SPOTs inst_root dir (ex. 50.45 MB)
	#	 i.e. how much space is used/needed for a new root dir
	my $ducmd = "/usr/bin/du -sm $spot_root_loc | /usr/bin/awk '{print \$1}'";

	my $inst_root_size;
	$inst_root_size = xCAT::Utils->runcmd("$ducmd", -1);
	if ($::RUNCMD_RC  != 0) {
		my $rsp;
		push @{$rsp->{data}}, "Could not run: \'$ducmd\'\n";
		if ($::VERBOSE) {
			push @{$rsp->{data}}, "$inst_root_size";
		}
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	# size needed should be size of root plus size of paging space
	#  - root and paging dirs are in the same FS
	#  - also dump - but that doesn't work for diskless now
	$inst_root_size += $pagingsize;

	#
	#  see how much free space we have in the root res location
	#

	#  Get the root res location 
	#  ex. /export/nim/root
    my $root_loc = &get_res_loc($rootname, $callback);
    if (!defined($root_loc) ) {
        my $rsp;
        push @{$rsp->{data}}, "Could not get the location of the SPOT/COSI named $root_loc.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	# get free space 
	# ex. 1971.06 (Free MB)
	my $dfcmd = qq~/usr/bin/df -m $root_loc | /usr/bin/awk '(NR==2){print \$3":"\$7}'~;

	my $output;
    $output = xCAT::Utils->runcmd("$dfcmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not run: \'$dfcmd\'\n";
        if ($::VERBOSE) {
            push @{$rsp->{data}}, "$output";
        }
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	my ($root_free_space, $FSname) = split(':', $output);

	#
	#  see if we need to increase the size of the fs
	#
	if ( $inst_root_size >= $root_free_space) {
		# try to increase the size of the root dir
		my $addsize = int ($inst_root_size+10);
		my $sizeattr = "-a size=+$addsize" . "M";
		my $chcmd = "/usr/sbin/chfs $sizeattr $FSname";

		my $output;
		$output = xCAT::Utils->runcmd("$chcmd", -1);
		if ($::RUNCMD_RC  != 0)
		{
			my $rsp;
			push @{$rsp->{data}}, "Could not run: \'$chcmd\'\n";
			if ($::VERBOSE) {
				push @{$rsp->{data}}, "$output";
			}
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
	}

	return 0;
}

#----------------------------------------------------------------------------

=head3  mknimres

       Create a NIM resource

        Returns:
                0 - OK
                1 - error
        Globals:

        Example:
			$rc = &mknimres($res_name, $res_type, $callback, $location, $spot_name);

        Comments:
=cut

#-----------------------------------------------------------------------------
sub mknimres {
    my $res_name = shift;
	my $type = shift;
    my $callback = shift;
	my $location = shift;
	my $spot_name = shift;

	if ($::VERBOSE) {
		my $rsp;
		push @{$rsp->{data}}, "Creating \'$res_name\'.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);
	}

	my $cmd = "/usr/sbin/nim -o define -t $type -a server=master ";

	# if this is a shared_root we need the spot name
    if ($type eq 'shared_root'){
        $cmd .= "-a spot=$spot_name ";
    }

	# where to put it - the default is /install
	if ($location) {
		$cmd .= "-a location=$location/$type/$res_name ";
	} else {
		$cmd .= "-a location=/install/nim/$type/$res_name ";
	}
	$cmd .= "$res_name  2>&1";
	if ($::VERBOSE) {
        my $rsp;
        push @{$rsp->{data}}, "Running command: \'$cmd\'.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }
	my $output = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0) {
		return 1;
	}
	return 0;
}

#----------------------------------------------------------------------------

=head3  updatespot

        Update the SPOT resource.

        Returns:
                0 - OK
                1 - error
        Globals:

        Example:
			$rc = &updatespot($spot_name, $lppsrcname, $callback);

        Comments:
=cut

#-----------------------------------------------------------------------------
sub updatespot {
	my $spot_name = shift;
	my $lppsrcname = shift;
    my $callback = shift;

	my $spot_loc;

	if ($::VERBOSE) {
		my $rsp;
		push @{$rsp->{data}}, "Updating $spot_name.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);
	}

	#
	#  add rpm.rte to the SPOT 
	#	- it contains gunzip which is needed on the nodes
	#   - also needed if user wants to install RPMs
	#	- assume the source for the spot also has the rpm.rte fileset
	#
	my $cmd = "/usr/sbin/nim -o showres $spot_name | grep rpm.rte";
	my $output = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0) {
		# it's not already installed - so install it

		if ($::VERBOSE) {
        	my $rsp;
        	push @{$rsp->{data}}, "Installing rpm.rte in the image.\n";
        	xCAT::MsgUtils->message("I", $rsp, $callback);
    	}

		my $cmd = "/usr/sbin/chcosi -i -s $lppsrcname -f rpm.rte $spot_name";
		my $output = xCAT::Utils->runcmd("$cmd", -1);
		if ($::RUNCMD_RC  != 0)
		{
			my $rsp;
			push @{$rsp->{data}}, "Could not run command \'$cmd\'. (rc = $::RUNCMD_RC)\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
	} # end - install rpm.rte

	#
	#  Get the SPOT location ( path to ../usr)
	#
	$spot_loc = &get_res_loc($spot_name, $callback);
	if (!defined($spot_loc) ) {
		my $rsp;
		push @{$rsp->{data}}, "Could not get the location of the SPOT/COSI named $spot_loc.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	#
	# Create ODMscript in the SPOT and modify the rc.dd-boot script
	#	- need for rnetboot to work - handles default console setting
	#
	my $odmscript = "$spot_loc/ODMscript";
	if ( !(-e $odmscript)) {
		if ($::VERBOSE) {
        	my $rsp;
        	push @{$rsp->{data}}, "Adding $odmscript to the image.\n";
        	xCAT::MsgUtils->message("I", $rsp, $callback);
    	}

		#  Create ODMscript script
		my $text = "CuAt:\n\tname = sys0\n\tattribute = syscons\n\tvalue = /dev/vty0\n\ttype = R\n\tgeneric =\n\trep = s\n\tnls_index = 0";

		if ( open(ODMSCRIPT, ">$odmscript") ) {
			print ODMSCRIPT $text;
			close(ODMSCRIPT);
		} else {
			my $rsp;
			push @{$rsp->{data}}, "Could not open $odmscript for writing.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
		my $cmd = "chmod 444 $odmscript";
		my @result = xCAT::Utils->runcmd("$cmd", -1);
		if ($::RUNCMD_RC  != 0)
		{
			my $rsp;
			push @{$rsp->{data}}, "Could not run the chmod command.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
	}

	# Modify the rc.dd-boot script to set the ODM correctly
	my $boot_file = "$spot_loc/lib/boot/network/rc.dd_boot";
	if (&update_dd_boot($boot_file, $callback) != 0) {
		my $rsp;
		push @{$rsp->{data}}, "Could not update the rc.dd_boot file in the SPOT.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	#
	# Copy the xcataixpost script to the SPOT/COSI and add an entry for it
	#	to the /etc/inittab file
	#
	if ($::VERBOSE) {
		my $rsp;
		push @{$rsp->{data}}, "Adding xcataixpost script to the image.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);
	}

	# copy the script
	my $cpcmd = "mkdir -m 644 -p $spot_loc/lpp/bos/inst_root/opt/xcat; cp /install/postscripts/xcataixpost $spot_loc/lpp/bos/inst_root/opt/xcat/xcataixpost; chmod +x $spot_loc/lpp/bos/inst_root/opt/xcat/xcataixpost";

	if ($::VERBOSE) {
		my $rsp;
		push @{$rsp->{data}}, "Running: \'$cpcmd\'\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);
	}

	my @result = xCAT::Utils->runcmd("$cpcmd", -1);
	if ($::RUNCMD_RC  != 0)
	{
		my $rsp;
        push @{$rsp->{data}}, "Could not copy the xcataixpost script to the SPOT.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }	

	# add an entry to the /etc/inittab file in the COSI/SPOT
	if (&update_inittab($spot_loc, $callback) != 0) {
		my $rsp;
        push @{$rsp->{data}}, "Could not update the /etc/inittab file in the SPOT.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
	}

	# add resolv.conf to image if data is provided in site table
	my $fileloc = "$spot_loc/lpp/bos/inst_root/etc";
	my $rc = &mk_resolv_conf_file($callback, $fileloc);

	# change the inst_root dir to "root system"
    # the default is "bin bin" which will not work if the user
    #   wants to use ssh as the remote shell for the nodes
    my $inst_root_dir = "$spot_loc/lpp/bos/inst_root";
    my $chcmd = "/usr/bin/chgrp system $inst_root_dir; /usr/bin/chown root $inst_root_dir";
    if ($::VERBOSE) {
        my $rsp;
        push @{$rsp->{data}}, "Running: \'$chcmd\'\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }

    my @result = xCAT::Utils->runcmd("$chcmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not change the group and owner for the inst_root directory.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	return 0;
}

#----------------------------------------------------------------------------


=head3   update_dd_boot

         Add the workaround for the default console to rc.dd_boot.

        Returns:
                0 - OK
                1 - error

        Comments:
=cut

#-----------------------------------------------------------------------------
sub update_dd_boot {

	my $dd_boot_file = shift;
	my $callback = shift;

	my @lines;

	# see if orig file exists
	if (-e $dd_boot_file) {

		# only update if it has not been done yet
        my $cmd = "cat $dd_boot_file | grep 'xCAT support'";
        my @result = xCAT::Utils->runcmd("$cmd", -1);
        if ($::RUNCMD_RC != 0) {
            if ($::VERBOSE) {
                my $rsp;
                push @{$rsp->{data}}, "Updating the $dd_boot_file file.\n";
                xCAT::MsgUtils->message("I", $rsp, $callback);
            }

			my $patch = qq~\n\t# xCAT support\n\tif [ -z "\$(odmget -qattribute=syscons CuAt)" ] \n\tthen\n\t  \${SHOWLED} 0x911\n\t  cp /usr/ODMscript /tmp/ODMscript\n\t  [ \$? -eq 0 ] && odmadd /tmp/ODMscript\n\tfi \n\n~;

			# back up the original file
			my $cmd    = "cp -f $dd_boot_file $dd_boot_file.orig";
 			my $output = xCAT::Utils->runcmd("$cmd", -1);
			if ($::RUNCMD_RC  != 0)
			{
				my $rsp;
        		push @{$rsp->{data}}, "Could not copy $dd_boot_file.\n";
        		xCAT::MsgUtils->message("E", $rsp, $callback);
        		return 1;
			}
	
			if ( open(DDBOOT, "<$dd_boot_file") ) {
				@lines = <DDBOOT>;
				close(DDBOOT);
			} else {
				my $rsp;
        		push @{$rsp->{data}}, "Could not open $dd_boot_file for reading.\n";
        		xCAT::MsgUtils->message("E", $rsp, $callback);
				return 1;
			}

			# remove the file
			my $cmd    = "rm $dd_boot_file";
			my $output = xCAT::Utils->runcmd("$cmd", -1);
			if ($::RUNCMD_RC  != 0)
    		{
				my $rsp;
        		push @{$rsp->{data}}, "Could not remove original $dd_boot_file.\n";
        		xCAT::MsgUtils->message("E", $rsp, $callback);
        		return 1;
    		}

			# Create a new one
			my $dontupdate=0;
			if ( open(DDBOOT, ">$dd_boot_file") ) {
				foreach my $l (@lines)
				{
					if ($l =~ /xCAT support/) {
						$dontupdate=1;
					}

					if ( ($l =~ /0x620/) && (!$dontupdate) ){
						# add the patch
						print DDBOOT $patch;
					}
					print DDBOOT $l;
				}
				close(DDBOOT);

			} else {
				my $rsp;
        		push @{$rsp->{data}}, "Could not open $dd_boot_file for writing.\n";
        		xCAT::MsgUtils->message("E", $rsp, $callback);
				return 1;
    		}

			if ($::VERBOSE) {
				my $rsp;
        		push @{$rsp->{data}}, "Updated $dd_boot_file.\n";
        		xCAT::MsgUtils->message("I", $rsp, $callback);
			}
		}
	} else {  # dd_boot file doesn't exist
		return 1;
	}

	return 0;
}

#----------------------------------------------------------------------------

=head3   prenimnodecust

        Preprocessing for the nimnodecust command.

        Runs on the xCAT management node only!

        Arguments:
        Returns:
                0 - OK - need to forward request
                1 - error - done
				2 - help or version - done
        Globals:
        Example:
        Comments:
            - If needed, copy files to the service nodes

=cut

#-----------------------------------------------------------------------------
sub prenimnodecust
{
    my $callback = shift;
	my $nodes = shift;

	my @nodelist;

	if ($nodes) {
		@nodelist =@$nodes;
	}

	if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
        &nimnodecust_usage($callback);
        return 1;
    }

	# parse the options
    if(!GetOptions(
        'h|help'    => \$::HELP,
		'b=s'		=> \$::BUNDLES,
        's=s'       => \$::LPPSOURCE,
        'p=s'     	=> \$::PACKAGELIST,
        'verbose|V' => \$::VERBOSE,
        'v|version' => \$::VERSION,))
    { return 1; }

    if ($::HELP) {
		&nimnodecust_usage($callback);
        return 2;
    }

	# display the version statement if -v or --verison is specified
    if ($::VERSION)
    {
        my $version=xCAT::Utils->Version();
        my $rsp;
        push @{$rsp->{data}}, "nimnodecust $version\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
        return 2;
    }

	# make sure the nodes are resolvable
    #  - if not then exit
    foreach my $n (@nodelist) {
        my $packed_ip = gethostbyname($n);
        if (!$packed_ip) {
            my $rsp;
            $rsp->{data}->[0] = "Could not resolve node $n.\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
    }

	# get the NIM primary server name
	my $nimprime = &getnimprime();
    chomp $nimprime;

	# get a list of packages that will be installed
	my @pkglist;
	my %bndloc;
	if ( $::PACKAGELIST ) {
		@pkglist = split(/,/, $::PACKAGELIST);
	} elsif ( $::BUNDLES ) {
		my @bndlist = split(/,/, $::BUNDLES);
		foreach my $bnd (@bndlist) {
			my ($rc, $list, $loc) =  &readBNDfile($callback, $bnd, $nimprime);
			push (@pkglist, @$list);
			$bndloc{$bnd} = $loc;
		}
	}

	# get the location of the lpp_source
	my $lpp_source_loc = &get_nim_attr_val($::LPPSOURCE, 'location', $callback, $nimprime);
	my $rpm_srcdir = "$lpp_source_loc/RPMS/ppc";
	my $instp_srcdir = "$lpp_source_loc/installp/ppc";

	# 
	#  Get the service nodes for this list of nodes
    #
    my $sn = xCAT::Utils->get_ServiceNode(\@nodelist, "xcat", "MN");
    if ($::ERROR_RC) {
        my $rsp;
        push @{$rsp->{data}}, "Could not get list of xCAT service nodes.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	# copy the packages to the service nodes - if needed
	foreach my $snkey (keys %$sn) {
		
		# if it's not me then we need to copy the pkgs there
		if (!&is_me($snkey) ) {

			my $cmdstr;
			if ( !&is_me($nimprime)) {
				$cmdstr = "xdsh $nimprime ";
			} else {
				$cmdstr = "";
			}

			foreach my $pkg (@pkglist) {
				my $rcpcmd;
				# note the xCAT rpm entries end in "*" - ex. "R:perl-xCAT-2.1*"
				if ( ($pkg =~ /rpm\s*$/) || ($pkg =~ /xCAT/) || ($pkg =~ /R:/)) {

					$rcpcmd = "$cmdstr 'xdcp $snkey $rpm_srcdir/$pkg $rpm_srcdir'";

					my $output = xCAT::Utils->runcmd("$rcpcmd", -1);
                    if ($::RUNCMD_RC  != 0) {
                        my $rsp;
                        push @{$rsp->{data}}, "Could not copy $pkg to $snkey.\n";
                        xCAT::MsgUtils->message("E", $rsp, $callback);
                    }

				} else {
					$rcpcmd .= "$cmdstr 'xdcp $snkey $instp_srcdir/$pkg $instp_srcdir'";

					my $output = xCAT::Utils->runcmd("$rcpcmd", -1);
					if ($::RUNCMD_RC  != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not copy $pkg to $snkey.\n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
					}

				}
			}
		}
	}

	# the NIM primary master may not be the management node
	my $cmdstr;
	if ( !&is_me($nimprime)) {
		$cmdstr = "xdsh $nimprime ";
	} else {
		$cmdstr = "";
	}

	#
    # if bundles provided then copy bnd files to SNs
    #
	if ( $::BUNDLES ) {
		foreach my $snkey (keys %$sn) {

			if (!&is_me($snkey) ) {
        		my @bndlist = split(/,/, $::BUNDLES);
        		foreach my $bnd (@bndlist) {
            		my $bnd_file_loc = $bndloc{$bnd};
					my $bnddir = dirname($bnd_file_loc);
					my $cmd = "$cmdstr 'xdcp $snkey $bnd_file_loc $bnddir'";
					my $output = xCAT::Utils->runcmd("$cmd", -1);
                    if ($::RUNCMD_RC  != 0) {
                        my $rsp;
                        push @{$rsp->{data}}, "Could not copy $bnd_file_loc to $snkey.\n"
;
                        xCAT::MsgUtils->message("E", $rsp, $callback);
                    }
        		}
			}	
		}
	}

	return (0, \%bndloc);
}

#----------------------------------------------------------------------------

=head3   nimnodecust

        Processing for the nimnodecust command.

		Does AIX node customization.

        Arguments:
        Returns:
                0 - OK 
                1 - error 
        Globals:
        Example:
        Comments:

=cut

#-----------------------------------------------------------------------------
sub nimnodecust
{
	my $callback = shift;
	my $locs = shift;
	my $nodes = shift;

	my %bndloc;
	if ($locs) {
		%bndloc = %{$locs};
	}

	my @nodelist;
	if ($nodes) {
        @nodelist =@$nodes;
    }

    if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
        &nimnodecust_usage($callback);
        return 1;
    }

    # parse the options
    if(!GetOptions(
        'h|help'    => \$::HELP,
        'b=s'       => \$::BUNDLES,
        's=s'       => \$::LPPSOURCE,
        'p=s'       => \$::PACKAGELIST,
        'verbose|V' => \$::VERBOSE,
        'v|version' => \$::VERSION,))
    { return 1; }

	my $Sname = &myxCATname();
	chomp $Sname;

	# get list of NIM machines defined locally

	my @machines = ();
    my $cmd = qq~/usr/sbin/lsnim -c machines | /usr/bin/cut -f1 -d' ' 2>/dev/null~;

    @machines = xCAT::Utils->runcmd("$cmd", -1);

	# see if lpp_source is defined locally
	my $cmd = qq~/usr/sbin/lsnim -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;

	my @nimresources = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0) {
		my $rsp;
		push @{$rsp->{data}}, "$Sname: Could not get NIM resource definitions.";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}
	if (!grep(/^$::LPPSOURCE$/, @nimresources)) {
		return 1;
	}

	# put together a cust cmd line for NIM
    my @pkglist;
	my $custcmd = "nim -o cust -a lpp_source=$::LPPSOURCE -a installp_flags=agQXY ";
    if ( $::PACKAGELIST ) {
        @pkglist = split(/,/, $::PACKAGELIST);
		$custcmd .= "-a filesets=\"";
		foreach my $p (@pkglist) {
			$custcmd .= " $p";
		}
		$custcmd .= "\"";
			
    }
	
	if ( $::BUNDLES ) {

        my @bndlist = split(/,/, $::BUNDLES);
        foreach my $bnd (@bndlist) {

			# check if bundles defined locally
			if (!grep(/^$bnd$/, @nimresources)) {
				# try to define it
				my $bcmd = "/usr/sbin/nim -Fo define -t installp_bundle -a server=master -a location=$bndloc{$bnd} $bnd";

				my $output = xCAT::Utils->runcmd("$bcmd", -1);
				if ($::RUNCMD_RC  != 0) {
					my $rsp;
					push @{$rsp->{data}}, "$Sname: Could not create bundle resource $bnd.\n";
					xCAT::MsgUtils->message("E", $rsp, $callback);
					return 1;
				}
			}
			# need a separate -a for each one ! 
			$custcmd .= " -a installp_bundle=$bnd ";		
        }
    }

	# for each node run NIM -o cust operation
	foreach my $n (@nodelist) {
		# TODO - check if machine is defined???

		# run the cust cmd - one for each node???
		my $cmd .= "$custcmd  $n";

		my $output = xCAT::Utils->runcmd("$cmd", -1);
		if ($::RUNCMD_RC  != 0) {
			my $rsp;
			push @{$rsp->{data}}, "$Sname: Could not customize node $n.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
	}

	return 0;
}

#----------------------------------------------------------------------------

=head3 readBNDfile

=cut

#-----------------------------------------------------------------------------
sub  readBNDfile
{
	my $callback = shift;
	my $BNDname = shift;
	my $nimprime = shift;

	my $junk;
	my @pkglist,
	my $pkgname;

	# get the location of the file from the NIM resource definition
	my $bnd_file_name = &get_nim_attr_val($BNDname, 'location', $callback, $nimprime);

	# open the file
	unless (open(BNDFILE, "<$bnd_file_name")) {
		return (1);
	}

	# get the names of the packages
	while (my $l = <BNDFILE>) {

		chomp $l;

		# skip blank and comment lines
        next if ($l =~ /^\s*$/ || $l =~ /^\s*#/);

		# bnd file entries look like - I:openssl.base or R:foobar.rpm
		if (grep(/:/, $l)) {
			($junk, $pkgname) = split(/:/, $l);
			push (@pkglist, $pkgname);
			#push (@pkglist, $l);  # keep the I & R??? - NO

		}
	}
	close(BNDFILE);

	return (0, \@pkglist, $bnd_file_name);
}


#----------------------------------------------------------------------------

=head3   prenimnodeset

        Preprocessing for the nimnodeset & mkdsklsnode command.

		Runs on the xCAT management node only!

        Arguments:
        Returns:
                 - OK
                 - error
        Globals:
        Example:
        Comments:
			- Gather info from the management node and/or the NIM 
			 	primary server and pass it along to the requests that
			 	go to the service nodes.
			- If needed, copy NIM files to the service nodes

=cut

#-----------------------------------------------------------------------------
sub prenimnodeset
{
    my $callback = shift;
    my $command = shift;
    my $error=0;

	if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
		if ($command eq 'mkdsklsnode') {
        	&mkdsklsnode_usage($callback);
		} else {
			&nimnodeset_usage($callback);
        }
        return (2);
    }

	# parse the options
    if(!GetOptions(
        'f|force'   => \$::FORCE,
        'h|help'    => \$::HELP,
        'i=s'       => \$::OSIMAGE,
        'n|new'     => \$::NEWNAME,
        'verbose|V' => \$::VERBOSE,
        'v|version' => \$::VERSION,))
    { 
		return (1); 
	}

	if ($::HELP) {
		if ($command eq 'mkdsklsnode') {
        	&mkdsklsnode_usage($callback);
		} else {
			&nimnodeset_usage($callback);
		}
        return (2);
    }

    # display the version statement if -v or --verison is specified
    if ($::VERSION)
    {
        my $version=xCAT::Utils->Version();
        my $rsp;
		if ($command eq 'mkdsklsnode') {
        	push @{$rsp->{data}}, "mkdsklsnode $version\n";
		} else {
			push @{$rsp->{data}}, "nimnodeset $version\n";
		}
        xCAT::MsgUtils->message("I", $rsp, $callback);
        return (2);
    }

	# if an osimage is included make sure it is defined
	if ($::OSIMAGE) {
		my @oslist = xCAT::DBobjUtils->getObjectsOfType('osimage');
		if (!grep(/^$::OSIMAGE$/, @oslist) ) {
			my $rsp;
			$rsp->{data}->[0] = "The xCAT osimage named \'$::OSIMAGE\' is not defined.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
	}

	my @nodelist;
    my %objtype;
    my %objhash;
    my %attrs;

	# the first arg should be a noderange - the other should be attr=val
    #  - put attr=val operands in %attrs hash
    while (my $a = shift(@ARGV))
    {
        if (!($a =~ /=/))
        {
            @nodelist = &noderange($a, 0);
        }
        else
        {
            # if it has an "=" sign its an attr=val - we hope
            my ($attr, $value) = $a =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;
            if (!defined($attr) || !defined($value))
            {
                my $rsp;
                $rsp->{data}->[0] = "Incorrect \'attr=val\' pair - $a\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 1;
            }
            # put attr=val in hash
            $attrs{$attr} = $value;
        }
    }

	my $Sname = &myxCATname();
	chomp $Sname;

    # make sure the nodes are resolvable
    #  - if not then exit
    foreach my $n (@nodelist) {
        my $packed_ip = gethostbyname($n);
        if (!$packed_ip) {
            my $rsp;
            $rsp->{data}->[0] = "$Sname: Could not resolve node $n.\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
    }

	#
	# get all the attrs for these node definitions
	#
    foreach my $o (@nodelist)
    {
        $objtype{$o} = 'node';
    }
    %objhash = xCAT::DBobjUtils->getobjdefs(\%objtype,$callback);
    if (!defined(%objhash))
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get xCAT object definitions.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return (1);
    }

	#
	# Get the network info for each node
	#
    my %nethash = xCAT::DBobjUtils->getNetwkInfo(\@nodelist, $callback);
    if (!defined(%nethash))
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get xCAT network definitions for one or
 more nodes.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return (1);
    }

	#
	# get a list of os images 
	#
	my @image_names;  # list of osimages needed
    my %nodeosi;  # hash of osimage for each node
    foreach my $node (@nodelist) {
        if ($::OSIMAGE){
            # from the command line
            $nodeosi{$node} = $::OSIMAGE;
        } else {
            if ( $objhash{$node}{profile} ) {
                $nodeosi{$node} = $objhash{$node}{profile};
            } else {
                my $rsp;
                push @{$rsp->{data}}, "Could not determine an OS image name for node \'$node\'.\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                next;
            }
        }
        if (!grep (/^$nodeosi{$node}$/, @image_names)) {
            push(@image_names, $nodeosi{$node});
        }
    }

	#
    # get the primary NIM master - default to management node
    #
    my $nimprime = &getnimprime();
    chomp $nimprime;

	#
	#  Get a list of all nim resource types
	#
	my $cmd;
	if (&is_me($nimprime)) {
		$cmd = qq~/usr/sbin/lsnim -P -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
	} else { 
		$cmd = qq~xdsh $nimprime "/usr/sbin/lsnim -P -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null"~;
	}

    my @nimrestypes = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get NIM resource definitions.";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return (1);
    }

	#
	# get the image defs from the DB
	#
	my %lochash;
	my %imghash;
	my %objtype;
	foreach my $m (@image_names) {
		$objtype{$m} = 'osimage';
	}
	%imghash = xCAT::DBobjUtils->getobjdefs(\%objtype,$callback);
	if (!defined(%imghash)) {
		my $rsp;
		push @{$rsp->{data}}, "Could not get xCAT osimage definitions.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return (1);
	}

	#
	# modify the image hash with whatever was passed in with attr=val
	#	- also add xcataixpost if appropriate
	#
	my $add_xcataixpost = 0;
	if (%attrs) {
 		foreach my $i (@image_names) {
			foreach my $restype (keys %{$imghash{$i}} ) {
				if ( $attrs{$restype} ) {
					$imghash{$i}{$restype} = $attrs{$restype};
				}
			}
		}
	}

	# add the "xcataixscript" script to each image def for standalone systems
	foreach my $i (@image_names) {
		if ( $imghash{$i}{nimtype} =~ /standalone/) {
			# add it to the list of scripts for this image
			if (defined($imghash{$i}{'script'}) ) {
				$imghash{$i}{'script'} .= ",xcataixscript";
			} else {
				$imghash{$i}{'script'} .= "xcataixscript";
			}

			# also make sure to create the resource
			$add_xcataixpost++;
		}
	}

	#
    # create a NIM script resource using xcataixscript
	#

	if ($add_xcataixpost) {  # if we have at least one standalone node

		my $pre;
		if (&is_me($nimprime)) {
			$pre = "";
		} else {
			$pre = "xdsh $nimprime";
		}

		my $createscript=0;
		# see if it already exists

		my $scmd = qq~$pre /usr/sbin/lsnim -l 'xcataixscript' 2>/dev/null~;
		xCAT::Utils->runcmd($scmd, 0);
		if ($::RUNCMD_RC != 0) {
			# doesn't exist so create it
			$createscript=1;
		} else {
			# it exists so see if it's in the correct location
			my $loc = &get_nim_attr_val('xcataixscript', 'location', $callback, $nimprime);

			# see if it's in the wrong place
# TODO - how handle migration????
			if ($loc ne "/install/nim/scripts/xcataixscript") {
				# need to remove this def and create a new one
				$createscript=1;

				my $rcmd = qq~$pre /usr/sbin/nim -Fo remove 'xcataixscript' 2>/dev/null~;
				xCAT::Utils->runcmd($rcmd, 0);
				if ($::RUNCMD_RC != 0) {
					# error - could not remove NIM xcataixscript script resource.
				}
			}

		}

		# create a new one if we need to
		if ($createscript) {
			# copy file to /install/nim/scripts
			my $ccmd = qq~$pre mkdir -m 644 -p /install/nim/scripts; cp /install/postscripts/xcataixscript /install/nim/scripts 2>/dev/null; chmod +x /install/nim/scripts/xcataixscript~;
			xCAT::Utils->runcmd($ccmd, 0);
			if ($::RUNCMD_RC != 0) {
				my $rsp;
				push @{$rsp->{data}}, "Could not copy xcataixscript.";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return 1;
			}

			# define the xcataixscript resource
			my $dcmd = qq~$pre /usr/sbin/nim -o define -t script -a server=master -a location=/install/nim/scripts/xcataixscript xcataixscript 2>/dev/null~;
			xCAT::Utils->runcmd($dcmd, 0);
			if ($::RUNCMD_RC != 0) {
				my $rsp;
				push @{$rsp->{data}}, "Could not create a NIM resource for xcataixscript.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return (1);
			}
		}

		# make sure we clean up the /etc/exports file of old post script
		my $ecmd = qq~$pre /usr/sbin/rmnfsexp -d /install/postscripts/xcataixpost -B 2>/dev/null~;
		xCAT::Utils->runcmd($ecmd, 0);

	#	$lochash{'xcataixpost'} = "/install/nim/scripts/xcataixpost";
	}

	#
	# create a hash containing the locations of the NIM resources 
	#	that are used for each osimage
	# - the NIM resource names are unique!
	#
	foreach my $i (@image_names) {
		foreach my $restype (keys %{$imghash{$i}} ) {
			my @reslist;
			if ( grep (/^$restype$/, @nimrestypes) ) {
				# spot, mksysb etc.
				my $resname = $imghash{$i}{$restype};

				# if comma list - split and put in list
				if ($resname) {
					foreach (split /,/,$resname) {
						chomp $_;
						push (@reslist, $_);
					}
				}
			}

			foreach my $res (@reslist) {
				# go to primary NIM master to get resource defs and 
				#	pick out locations
				# TODO - handle NIM prime!!
				my $loc = &get_nim_attr_val($res, "location", $callback, $nimprime);

				# add to hash
				$lochash{$res} = "$loc";
			}
		}
	}

	# make sure any diskless images are updated
	foreach my $i (@image_names) {
        if ( !($imghash{$i}{nimtype} =~ /standalone/)) {
			# must be diskless or dataless so update spot
			my $rc=&updatespot($imghash{$i}{'spot'}, $imghash{$i}{'lpp_source'}, $callback);
			if ($rc != 0) {
				my $rsp;
				push @{$rsp->{data}}, "Could not update the SPOT resource named \'$imghash{$i}{'spot'}\'.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return (1);
			}
        }
    }

	# Checks the various credential files on the Management Node to
    #   make sure the permission are correct for using and transferring
    #   to the nodes and service nodes.
    #   Also removes /install/postscripts/etc/xcat/cfgloc if found
    my $result= xCAT::Utils->checkCredFiles($callback);

	#####################################################
	#
	#	Copy files/dirs to remote service nodes so they can be
	#		defined locally when this cmd runs there 
	#
	######################################################
	if (&doSNcopy($callback, \@nodelist, $nimprime, \@nimrestypes, \%imghash, \%lochash, \%nodeosi)) {
		my $rsp;
		push @{$rsp->{data}}, "Could not copy NIM resources to the xCAT service nodes.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return (1);
	}

	# pass this along to the process_request routine
	return (0, \%objhash, \%nethash, \%imghash, \%lochash, \%attrs);
}

#----------------------------------------------------------------------------

=head3   bkupNIMresources

        Backup NIM spot or lpp_source resource

        Arguments:
        Returns:
                file name  - OK
                undef - error
        Globals:
        Example:
        Comments:

	my $bkfile = &bkupNIMresources($callback, $bkdir, $resname);
=cut

#-----------------------------------------------------------------------------
sub bkupNIMresources
{
    my $callback = shift;
    my $bkdir = shift;
    my $resname = shift;

	# create file name
	my $dir = dirname($bkdir);
	my $bkfile = $dir . "/" . $resname . ".bk";

	# remove the old file 
	if (-e $bkfile) {
		my $cmd = "rm $bkfile";
		my $output = xCAT::Utils->runcmd("$cmd", -1);
		if ($::RUNCMD_RC  != 0) {
			my $rsp;
			push @{$rsp->{data}}, "Could not remove $bkfile.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback)
		}
	}

	# create a new backup file
	my $bkcmd = "find $bkdir -print |backup -ivqf $bkfile";

	if ($::VERBOSE) {
		my $rsp;
		push @{$rsp->{data}}, "Backing up $bkdir. Running command- \'$bkcmd\'";
		xCAT::MsgUtils->message("I", $rsp, $callback);
	}

	my $output = xCAT::Utils->runcmd("$bkcmd", -1);
	if ($::RUNCMD_RC  != 0) {
		my $rsp;
		push @{$rsp->{data}}, "Could not create $bkfile.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return undef;
	}
	
	return $bkfile;
}

#----------------------------------------------------------------------------

=head3   tarNIMresources

        Tar and gzip NIM spot & lpp_source resources

        Arguments:
        Returns:
                file name  - OK
                undef - error
        Globals:
        Example:
        Comments:

	my $gzfile = &tarNIMresources($callback, $tardir, $resname);
=cut

#-----------------------------------------------------------------------------
sub tarNIMresources
{
    my $callback = shift;
    my $tardir = shift;
    my $resname = shift;

	# create tar file names
	my $tarfile = $tardir . "/" . $resname . ".tar";
	my $gzfile = $tarfile . ".gz";

	# remove the old file 
	if (-e $gzfile) {
		my $cmd = "rm $gzfile";
		my $output = xCAT::Utils->runcmd("$cmd", -1);
		if ($::RUNCMD_RC  != 0) {
			my $rsp;
			push @{$rsp->{data}}, "Could not remove $gzfile.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback)
		}
	}

	# create a new tar file
	my $tarcmd = "tar -cvpf $tarfile $tardir 2>/dev/null; gzip $tarfile";

	my $output = xCAT::Utils->runcmd("$tarcmd", -1);
	if ($::RUNCMD_RC  != 0) {
		my $rsp;
		push @{$rsp->{data}}, "Could not archive $tarfile.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return undef;
	}
	
	return $gzfile;
}

#----------------------------------------------------------------------------

=head3   copyres

        Copy NIM resource files/dirs to remote service nodes 

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:
        Example:
        Comments:

=cut

#-----------------------------------------------------------------------------
sub copyres
{
    my $callback = shift;
	my $dest = shift;
	my $restype = shift;
	my $resloc = shift;
	my $resname = shift;
	my $nimprime = shift;

	# get the directory location of the resource
    #  - could be the NIM location or may have to strip off a file name
    my $dir;
    if ( $restype eq "lpp_source") {
        $dir = $resloc;
    } else {
        $dir = dirname($resloc);
    }
    chomp $dir;

	# make sure the directory loc is created on the SN
	my $cmd = "xdsh $dest '/usr/bin/mkdir -m 644 -p $dir'";

    my $output = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not create $dir on $dest.\n";
        if ($::VERBOSE) {
            push @{$rsp->{data}}, "$output\n";
        }
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return undef;
    }

	# how much free space is available on the SN ($dest)?
	my $dfcmd = qq~xdsh $dest /usr/bin/df -m $dir |/usr/bin/awk '(NR==2)'~;

    $output = xCAT::Utils->runcmd("$dfcmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not run: \'$dfcmd\'\n";
        if ($::VERBOSE) {
            push @{$rsp->{data}}, "$output";
        }
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }
	my @fslist = split(/\s+/, $output);

    my $free_space = $fslist[3];
	my $FSname = $fslist[7];

	# How much space is the resource using?
	my $ducmd = qq~/usr/bin/du -sm $dir | /usr/bin/awk '{print \$1}'~;

	my $reqsize = xCAT::Utils->runcmd("$ducmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not run: \'$ducmd\'\n";
        if ($::VERBOSE) {
            push @{$rsp->{data}}, "$reqsize";
        }
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	# how much space do we need
	my $needspace;
	if (($restype eq 'lpp_source') || ($restype eq 'spot')) {
		# need size of resource plus size of tar file plus fudge factor
		$needspace = int ($reqsize + $reqsize + 100);
	} else {
		$needspace = int ($reqsize+10);
	}

	# increase FS if needed
	my $addsize = 0;
	if ( $needspace > $free_space) {
		# how much should we increase FS?
		$addsize = int ($needspace - $free_space);
        my $sizeattr = "-a size=+$addsize" . "M";
		my $chcmd = "xdsh $dest /usr/sbin/chfs $sizeattr $FSname";

        my $output;
        $output = xCAT::Utils->runcmd("$chcmd", -1);
        if ($::RUNCMD_RC  != 0)
        {
            my $rsp;
            push @{$rsp->{data}}, "Could not run: \'$chcmd\'\n";
            if ($::VERBOSE) {
                push @{$rsp->{data}}, "$output";
            }
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
    }

#	if ($::VERBOSE) {
#        my $rsp;
#        push @{$rsp->{data}}, "Space available on $dest=$free_space, space needed=$needspace, amount of space that will be added is \'$addsize\'\n";
#        xCAT::MsgUtils->message("I", $rsp, $callback);
#    }

	# do copy from NIM primary
	my $cpcmd;
	if ( !&is_me($nimprime)) {
		# if NIM primary is another system
		$cpcmd = "xdsh $nimprime ";
	} else {
		$cpcmd = "";
	}

	# if res is spot or lpp_source then
    #   backup dir it first!
	my $bkdir;  # directory to backup
	if ( $restype eq "lpp_source") {
		$bkdir = $resloc;
		# Ex. /install/nim/lpp_source/61D_lpp_source
		my $dir = dirname($bkdir);
		# ex. /install/nim/lpp_source
		my $bkfile = $dir . "/" . $resname . ".bk";
		if (!grep(/^$resname$/, @::resbacked)) {
			$bkfile = &bkupNIMresources($callback, $bkdir, $resname);
			if (!defined($bkfile)) {
				my $rsp;
				push @{$rsp->{data}}, "Could not archive $bkdir.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return 1;
			}
			push @::resbacked, $resname;
			push @::removebk, $bkfile;
		}
	
		# copy the file to the SN
		$cpcmd .= "xdcp $dest $bkfile $dir 2>/dev/null";
	} elsif ($restype eq 'spot') {
		$bkdir = dirname($resloc);
		# ex. /install/nim/spot/61dimg

		my $dir = dirname($bkdir);
		# ex. /install/nim/spot

		my $bkfile = $dir . "/" . $resname . ".bk";
		if (!grep(/^$resname$/, @::resbacked) ){
			$bkfile = &bkupNIMresources($callback, $bkdir, $resname);
			if (!defined($bkfile)) {
				my $rsp;
				push @{$rsp->{data}}, "Could not archive $bkdir.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return 1;
			}
			push @::resbacked, $resname;
			push @::removebk, $bkfile;
		}

		# copy the file to the SN
        $cpcmd .= "xdcp $dest $bkfile $dir 2>/dev/null";

	} else {

		# copy the resource file to the SN dir
		# covers- bosinst_data, script, resolv_conf, installp_bundle, mksysb
		# - the NIM location includes the actual file name
		my $dir = dirname($resloc);
		$cpcmd .= "xdcp $dest $resloc $dir 2>/dev/null";
	}

	$output = xCAT::Utils->runcmd("$cpcmd",-1);
	if ($::RUNCMD_RC  != 0) {
		my $rsp;
		push @{$rsp->{data}}, "Could not copy NIM resource $resname to $dest.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	if ($::VERBOSE) {
        my $rsp;
        push @{$rsp->{data}}, "Copying NIM resource to service node. Running command \'$cpcmd\'.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }

	return 0;    
}

#----------------------------------------------------------------------------

=head3   doSNcopy

        Copy NIM resource files/dirs to remote service nodes so they can be
           defined locally

		Also copy /etc/hosts to make sure we have name res for nodes
            from SN

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:
        Example:
        Comments:

=cut

#-----------------------------------------------------------------------------
sub doSNcopy
{
	my $callback = shift;
    my $nodes = shift;
	my $nimprime = shift;
	my $restypes = shift;
    my $imaghash = shift;
    my $locs = shift;
	my $nosi = shift;

    my %lochash = %{$locs};
    my %imghash = %{$imaghash};
    my @nodelist = @$nodes;
	my @nimrestypes = @$restypes;
	my %nodeosi = %{$nosi};

	#
	#  Get a list of nodes for each service node
	#
	my $sn = xCAT::Utils->get_ServiceNode(\@nodelist, "xcat", "MN");
	if ($::ERROR_RC) {
		my $rsp;
		push @{$rsp->{data}}, "Could not get list of xCAT service nodes.";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	#
	# Get a list of images for each SN
	#
	my %SNosi;
	foreach my $snkey (keys %$sn) {
		my @nodes = @{$sn->{$snkey}};
		foreach my $n (@nodes) {
			if (!grep (/^$nodeosi{$n}$/, @{$SNosi{$snkey}}) ) {
				push (@{$SNosi{$snkey}}, $nodeosi{$n});
			}
		}
	}

	#
	#  For each SN
	#	- copy whatever is needed to the SNs
	#
	
	# keep track if spot or lpp_source has already been backed up
	@::resbacked=();

	# list of backup files to remove from the MN when done
    @::removebk=();

	foreach my $snkey (keys %$sn) {
		my @nimresources;
		if (!&is_me($snkey) ) {

			# running on the management node so
			# copy the /etc/hosts file to the SN
			my $rcpcmd = "xdcp $snkey /etc/hosts /etc ";
			if ($::VERBOSE) {
                my $rsp;
                push @{$rsp->{data}}, "Running: \'xdcp $snkey /etc/hosts /etc\'\n";
                xCAT::MsgUtils->message("I", $rsp, $callback);
            }
			my $output = xCAT::Utils->runcmd("$rcpcmd", -1);
			if ($::RUNCMD_RC  != 0) {
				my $rsp;
				push @{$rsp->{data}}, "Could not copy /etc/hosts to $snkey.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
			}

			# update the postscripts on the SN 
			my $lscmd = "xdsh $snkey 'ls /install/postscripts' >/dev/null 2>&1";
			my $output = xCAT::Utils->runcmd("$lscmd", -1);
			if ($::RUNCMD_RC  == 0) {	
				# if the dir exists then we can update it
				my $cpcmd = "xdcp $snkey -p -R /install/postscripts/* /install/postscripts ";
				if ($::VERBOSE) {
					my $rsp;
					push @{$rsp->{data}}, "Running: \'$cpcmd\'\n";
					xCAT::MsgUtils->message("I", $rsp, $callback);
				}
				my $output = xCAT::Utils->runcmd("$cpcmd", -1);
				if ($::RUNCMD_RC  != 0) {
					my $rsp;
					push @{$rsp->{data}}, "Could not copy /install/postscripts to $snkey.\n";
					xCAT::MsgUtils->message("E", $rsp, $callback);
				}
			}

			# copy NIM files/dir to the remote SN - so that
			#	the NIM res defs can be created when the rest of this cmd
			# 	runs on that SN

			# get a list of the resources that are defined on the SN
			my $cmd = qq~xdsh $snkey "/usr/sbin/lsnim -c resources | /usr/bin/cut -f1 -d' '"~;

			my @resources = xCAT::Utils->runcmd("$cmd", -1);
            if ($::RUNCMD_RC  != 0)
            {
                my $rsp;
                push @{$rsp->{data}}, "Could not get NIM resource definitions.";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }

            foreach my $r (@resources) {
                my ($node, $nimres) = split(': ', $r);
                chomp $nimres;
                push(@nimresources, $nimres);
            }

			# for each image
			foreach my $image (@{$SNosi{$snkey}}) {
				# for each resource
				foreach my $restype (keys (%{$imghash{$image}})) {

					my $nimtype=$imghash{$image}{'nimtype'};
					if (($nimtype ne 'standalone')  && ($restype eq 'lpp_source') ) {
						# don't copy lpp_source for diskless/dataless nodes
						next;
					}

					# if a valid NIM type and a value is set
					if (($imghash{$image}{$restype}) && (grep(/^$restype$/, @nimrestypes))) {
						# could have a comma separated list - ex. script etc.
					  	foreach my $res (split /,/, $imghash{$image}{$restype}) {
							chomp $res;

							# if the resources are not defined on the SN
							if (!grep(/^$res$/, @nimresources)) 
							{

								# copy appropriate files to the SN
								# use same location on all NIM servers
								# cp dirs/files to corresponding dirs on 
								#   each SN - always in /install!!!
								# only care about these resource types for now

								my @dorestypes=("mksysb", "resolv_conf", "script", "installp_bundle", "bosinst_data", "lpp_source", "spot");
								if (grep(/^$restype$/, @dorestypes)) {
									my $resloc = $lochash{$res};

									#   if ($::VERBOSE) {
									if (0) {
										my $rsp;
										push @{$rsp->{data}}, "Copying NIM resources to the xCAT $snkey service node. This could take a while.";
										xCAT::MsgUtils->message("I", $rsp, $callback);

									   }

									if (&copyres($callback, $snkey, $restype, $resloc, $res, $nimprime) ) {  
										# error
									}
								}

							} # end - if res not defined
					  	} # end foreach resource of this type
					} # end - if it's a valid res type
				} # end - for each resource
			} # end - for each image
		} # end - if the SN is not me
	} # end - for each SN

	# remove any lpp_source or spot backup files that were created
    foreach my $file (@::removebk) {
        my $rmcmd = "/usr/bin/rm -f $file";
        my $output = xCAT::Utils->runcmd("$rmcmd", -1);
        if ($::RUNCMD_RC  != 0) {
            my $rsp;
            push @{$rsp->{data}}, "Could not remove backup file: $file\n";
            if ($::VERBOSE) {
                push @{$rsp->{data}}, "$output";
            }
            xCAT::MsgUtils->message("E", $rsp, $callback);
        }
    }

	return 0;
}

#----------------------------------------------------------------------------

=head3   restore_request

		Restores an xcatd request from a remote management server
		into the proper format by removing arrays that were added by
		XML and removing tags that were added to numeric hash keys.

		Arguments:
        Returns:
                ptr to hash
                undef
        Globals:
        Example:
        Comments:

=cut

#-----------------------------------------------------------------------------
sub restore_request
{
	my $in_struct = shift;
	my $callback = shift;

	my $out_struct;

	if (ref($in_struct) eq "ARRAY") {
		# flatten the array it it has only one element 
		#  otherwise leave it alone
		if ( scalar(@$in_struct) == 1) {
    		return (&restore_request($in_struct->[0]));
		} else {
			return ($in_struct);
		}
	}

	if (ref($in_struct) eq "HASH") {
    	foreach my $struct_key (keys %{$in_struct}) {
        	my $stripped_key = $struct_key;
        	$stripped_key =~ s/^xxXCATxx(\d)/$1/;
			# do not flatten the arg or node arrays
			if (($stripped_key =~ /^arg$/) || ($stripped_key =~ /^node$/)){
				$out_struct->{$stripped_key} = $in_struct->{$struct_key};
			} else {
        		$out_struct->{$stripped_key} = &restore_request($in_struct->{$struct_key});
			}
    	}
    	return $out_struct;
	}

	if ((ref($in_struct) eq "SCALAR") || (ref(\$in_struct) eq "SCALAR")) {
    	return ($in_struct);
	}

	print "Unsupported data reference in restore_request().\n";
	return undef;
}

#----------------------------------------------------------------------------

=head3   taghash

		Add a non-numeric tag to any hash keys that are numeric.  

		Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:
        Example:
        Comments:
			XML will choke on numeric values.  This happens when including
			a hash in a request to a remote service node.

=cut

#-----------------------------------------------------------------------
sub taghash
{
    my $hash = shift;

    if (ref($hash) eq "HASH") {
        foreach my $k (keys %{$hash}) {
            if ($k =~ /^(\d)./ ) {
                my $tagged_key = "xxXCATxx" . $k;
                $hash->{$tagged_key} = $hash->{$k};
				delete($hash->{$k});
            }
        }
        return 0;
    } else {
        return 1;
    }
}

#----------------------------------------------------------------------------

=head3   mkdsklsnode

        Support for the mkdsklsnode command.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Globals:
        Example:
        Comments:

		This runs on the service node in a hierarchical env

=cut

#-----------------------------------------------------------------------------
sub mkdsklsnode 
{
	my $callback = shift;
	my $nodes = shift;
	my $nodehash = shift;
	my $nethash = shift;
	my $imaghash = shift;
	my $locs = shift;
	my $subreq = shift;

	my %lochash = %{$locs};
	my %objhash = %{$nodehash};
	my %nethash = %{$nethash};
	my %imagehash = %{$imaghash};
	my @nodelist = @$nodes;

	my $error=0;
	my @nodesfailed;
	my $image_name;

	# get name as known by xCAT 
	my $Sname = &myxCATname();
	chomp $Sname;

	# make sure the nodes are resolvable
	#  - if not then exit
	foreach my $n (@nodelist) {
		my $packed_ip = gethostbyname($n);
		if (!$packed_ip) {
			my $rsp;
			$rsp->{data}->[0] = "$Sname: Could not resolve node $n.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
	}

	# some subroutines require a global callback var
	#	- need to change to pass in the callback 
	#	- just set global for now
    $::callback=$callback;

	if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
        &mkdsklsnode_usage($callback);
        return 0;
    }

	# parse the options
	if(!GetOptions(
		'f|force'	=> \$::FORCE,
		'h|help'    => \$::HELP,
		'i=s'       => \$::OSIMAGE,
		'n|new'		=> \$::NEWNAME,
		'verbose|V' => \$::VERBOSE,
		'v|version' => \$::VERSION,))
	{
		return 1;
	}

	my %objtype;
	my %attrs;

    #  - put attr=val operands in %attrs hash
    while (my $a = shift(@ARGV))
    {
        if ($a =~ /=/)
        {
            # if it has an "=" sign its an attr=val - we hope
            my ($attr, $value) = $a =~ /^\s*(\S+?)\s*=\s*(\S*.*)$/;
            if (!defined($attr) || !defined($value))
            {
                my $rsp;
                $rsp->{data}->[0] = "$Sname: Incorrect \'attr=val\' pair - $a\n";
                xCAT::MsgUtils->message("E", $rsp, $::callback);
                return 1;
            }
            # put attr=val in hash
			$attrs{$attr} = $value;
        }
    }

    #
    #  Get a list of the defined NIM machines
	#    these are machines defined on this server
    #
	my @machines = ();
    my $cmd = qq~/usr/sbin/lsnim -c machines | /usr/bin/cut -f1 -d' ' 2>/dev/nu
ll~;

    @machines = xCAT::Utils->runcmd("$cmd", -1);
	# don't fail - maybe just don't have any defined!

	#
	# get all the image names and create a hash of osimage 
	#	names for each node
	#
	my @image_names;
	my %nodeosi;
	foreach my $node (@nodelist) {
		if ($::OSIMAGE){
			# from the command line
			$nodeosi{$node} = $::OSIMAGE;
		} elsif ( $objhash{$node}{profile} ) {
			$nodeosi{$node} = $objhash{$node}{profile};
		}
		if (!grep (/^$nodeosi{$node}$/, @image_names)) {
			push(@image_names, $nodeosi{$node});
		}
	}
	
	if (scalar(@image_names) == 0)  {
		# if no images then error
		my $rsp;
		push @{$rsp->{data}}, "$Sname: Could not determine which xCAT osimage to use.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	#
    # get the primary NIM master - 
    #
    my $nimprime = &getnimprime();
	chomp $nimprime;

	#
	# if this isn't the NIM primary then make sure the local NIM defs 
	#	have been created 
	#
	if (!&is_me($nimprime)) {
		&make_SN_resource($callback, \@nodelist, \@image_names, \%imagehash, \%lochash, \%nethash);
	} else {
        # if this is the NIM primary make sure we update any shared_root
        # resources that are being used
        foreach my $img (@image_names) {

            # if have shared_root
            if ($imagehash{$img}{shared_root}) {
                # if it's allocated then don't update it
                my $alloc_count = &get_nim_attr_val($imagehash{$img}{shared_root}, "alloc_count", $callback);
                if ( defined($alloc_count) && ($alloc_count != 0) ){
                    my $rsp;
                    push @{$rsp->{data}}, "The resource named \'$imagehash{$img}{shared_root}\' is currently allocated. It will not be updated.\n";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                    next;
                }
 				if ($::VERBOSE) {
                    my $rsp;
                    push @{$rsp->{data}}, "$Sname: Updating \'$imagehash{$img}{shared_root}\'.\n";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                }
                my $scmd = "nim -F -o sync_roots $imagehash{$img}{spot}";
                my $output = xCAT::Utils->runcmd("$scmd", -1);
                if ($::RUNCMD_RC  != 0) {
                    my $rsp;
                    push @{$rsp->{data}}, "$Sname: Could not update $imagehash{$img}{shared_root}.\n";
                    if ($::VERBOSE) {
                        push @{$rsp->{data}}, "$output";
                    }
                    xCAT::MsgUtils->message("E", $rsp, $callback);
                }
            }
        }
    } # end re-sync shared_root

	#
	# define and initialize the diskless/dataless nodes
	#
	my $error=0;
	my @nodesfailed;
	my $node_syncfile = xCAT::SvrUtils->getsynclistfile($nodes);
	foreach my $node (@nodelist) 
	{
		my $image_name = $nodeosi{$node};
		chomp $image_name;

		# set the NIM machine type
		my $type="diskless";
		if ($imagehash{$image_name}{nimtype} ) {
			$type = $imagehash{$image_name}{nimtype};
		}
		chomp $type;

		if ( ($type =~ /standalone/) ) {
            #error - only support diskless/dataless
            my $rsp;
            push @{$rsp->{data}}, "$Sname: Use the nimnodeset command to initialize NIM standalone type nodes.\n";
            xCAT::MsgUtils->message("E", $rsp, $callback);
            $error++;
            push(@nodesfailed, $node);
            next;
        }
		
		# generate a NIM client name
		my $nim_name;
		if ($::NEWNAME) {
			# generate a new nim name 
			# "<xcat_node_name>_<image_name>"
			my $name;
			($name = $node) =~ s/\..*$//; # make sure we have the short hostname
			$nim_name=$name . "_" . $image_name;
		} else {
			# the nim name is the short hostname of our node
			($nim_name = $node) =~ s/\..*$//;
		}
		chomp $nim_name;

		# need the short host name for NIM cmds 
        my $nodeshorthost;
        ($nodeshorthost = $node) =~ s/\..*$//;
        chomp $nodeshorthost;

		#
		#  define the new NIM machine
		#

		# 	see if it's already defined first
		if (grep(/^$nim_name$/, @machines)) { 
			if ($::FORCE) {
				# get rid of the old definition
				if ($::VERBOSE) {
					my $rsp;
					push @{$rsp->{data}}, "$Sname: Removing NIM definition for $nim_name.\n";
					xCAT::MsgUtils->message("I", $rsp, $callback);
				}
				
				my $rmcmd = "/usr/sbin/nim -Fo reset $nim_name;/usr/sbin/nim -Fo deallocate -a subclass=all $nim_name;/usr/sbin/nim -Fo remove $nim_name";
				my $output = xCAT::Utils->runcmd("$rmcmd", -1);
				if ($::RUNCMD_RC  != 0) {
					my $rsp;
					push @{$rsp->{data}}, "$Sname: Could not remove the existing NIM object named \'$nim_name\'.\n";
					if ($::VERBOSE) {
						push @{$rsp->{data}}, "$output";
					}
					xCAT::MsgUtils->message("E", $rsp, $callback);
					$error++;
					push(@nodesfailed, $node);
					next;
				}

			} else { # no force
				my $rsp;
				push @{$rsp->{data}}, "$Sname: The node \'$node\' is already defined. Use the force option to remove and reinitialize.";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				push(@nodesfailed, $node);
				$error++;
				next;
			}

		} # end already defined

       	# get, check the node IP
# TODO - need IPv6 update
       	my $IP = inet_ntoa(inet_aton($node));
       	chomp $IP;
       	unless ($IP =~ /\d+\.\d+\.\d+\.\d+/)
       	{
			my $rsp;
			push @{$rsp->{data}}, "$Sname: Could not get valid IP address for node $node.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			$error++;
			push(@nodesfailed, $node);
			next;
       	}

		# check for required attrs
		if (($type ne "standalone")) {

			# could be diskless or dataless
			# mask, gateway, cosi, root, dump, paging
# TODO - need to fix this check for shared_root
			if (!$nethash{$node}{'mask'} || !$nethash{$node}{'gateway'} || !$imagehash{$image_name}{spot}) {
				my $rsp;
           		push @{$rsp->{data}}, "$Sname: Missing required information for node \'$node\'.\n";
           		xCAT::MsgUtils->message("E", $rsp, $callback);
				$error++;
           		push(@nodesfailed, $node);
           		next;
       		}
		}

		# diskless also needs a defined paging res
		if ($type eq "diskless" ) {
			if (!$imagehash{$image_name}{paging} ) {
				my $rsp;
				push @{$rsp->{data}}, "$Sname: Missing required information for node \'$node\'.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				$error++;
				push(@nodesfailed, $node);
				next;
			}
		}	

		# set some default values
		# overwrite with cmd line values - if any
		my $speed="100";
       	my $duplex="full";
		if ($attrs{duplex}) {
			$duplex=$attrs{duplex};
		}
		if ($attrs{speed}) {
			$speed=$attrs{speed};
		}

		# define the node 
		my $defcmd = "/usr/sbin/nim -o define -t $type ";
		if ($::NEWNAME) {
            $defcmd .= "-a if1='find_net $nodeshorthost 0' ";
        } else {
            $objhash{$node}{'mac'}  =~ s/://g;  # strip out colons if any
            $defcmd .= "-a if1='find_net $nodeshorthost $objhash{$node}{'mac'}' ";
        }
		$defcmd .= "-a cable_type1=N/A -a netboot_kernel=mp ";
		$defcmd .= "-a net_definition='ent $nethash{$node}{'mask'} $nethash{$node}{'gateway'}' ";
		$defcmd .= "-a net_settings1='$speed $duplex' ";
		$defcmd .= "$nim_name  2>&1";
		if ($::VERBOSE) {
           	my $rsp;
           	push @{$rsp->{data}}, "$Sname: Creating NIM node definition.\n";
           	push @{$rsp->{data}}, "Running: \'$defcmd\'\n";
           	xCAT::MsgUtils->message("I", $rsp, $callback);
		}
       	my $output = xCAT::Utils->runcmd("$defcmd", -1);
       	if ($::RUNCMD_RC  != 0)
       	{
           	my $rsp;
           	push @{$rsp->{data}}, "$Sname: Could not create a NIM definition for \'$nim_name\'.\n";
           	if ($::VERBOSE) {
             	push @{$rsp->{data}}, "$output";
           	}
         	xCAT::MsgUtils->message("E", $rsp, $callback);
           	$error++;
           	push(@nodesfailed, $node);
           	next;
       	}

		#
		# initialize node
		#

		my $psize="64";
		if ($attrs{psize}) {
			$psize=$attrs{psize};
		}

		my $arg_string;
        if ($imagehash{$image_name}{shared_root}) {
            $arg_string="-a spot=$imagehash{$image_name}{spot} -a shared_root=$imagehash{$image_name}{shared_root} -a size=$psize ";
        } else {
            $arg_string="-a spot=$imagehash{$image_name}{spot} -a root=$imagehash{$image_name}{root} -a size=$psize ";
        }

		# the rest of these resources may or may not be provided
		if ($imagehash{$image_name}{paging} ) {
			$arg_string .= "-a paging=$imagehash{$image_name}{paging} "
		}
		if ($imagehash{$image_name}{resolv_conf}) {
			$arg_string .= "-a resolv_conf=$imagehash{$image_name}{resolv_conf} ";
		}
		if ($imagehash{$image_name}{dump} ) {
			$arg_string .= "-a dump=$imagehash{$image_name}{dump} "
		}
		if ($imagehash{$image_name}{home}) {
			$arg_string .= "-a home=$imagehash{$image_name}{home} ";
		}
		if ($imagehash{$image_name}{tmp}) {	
			$arg_string .= "-a tmp=$imagehash{$image_name}{tmp} ";
		}
		if ($imagehash{$image_name}{shared_home}) {
			$arg_string .= "-a shared_home=$imagehash{$image_name}{shared_home} ";
		}

		#
		#  make sure we have enough space for the new node root dir
		#
# TODO - test FS resize
if (0) {
		if (&enoughspace($imagehash{$image_name}{spot}, $imagehash{$image_name}{root}, $psize, $callback) != 0) {
			my $rsp;
			push @{$rsp->{data}}, "Could not initialize node \'$node\'\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}
}

		my $initcmd;
		if ( $type eq "diskless") {
			$initcmd="/usr/sbin/nim -o dkls_init $arg_string $nim_name 2>&1";
		} else {
			$initcmd="/usr/sbin/nim -o dtls_init $arg_string $nim_name 2>&1";
		}

		my $time=`date | cut -f5 -d' '`;
		chomp $time;
		my $rsp;
		push @{$rsp->{data}}, "$Sname: Initializing NIM machine \'$nim_name\'. This could take a while.\n";
		if ($::VERBOSE) {
            push @{$rsp->{data}}, "Running: \'$initcmd\'\n";
        }
		xCAT::MsgUtils->message("I", $rsp, $callback);

       	my $output = xCAT::Utils->runcmd("$initcmd", -1);
       	if ($::RUNCMD_RC  != 0)
       	{
			my $rsp;
			push @{$rsp->{data}}, "$Sname: Could not initialize NIM client named \'$nim_name\'.\n";
			if ($::VERBOSE) {
				push @{$rsp->{data}}, "$output";
	   		}
			xCAT::MsgUtils->message("E", $rsp, $callback);
			$error++;
			push(@nodesfailed, $node);
			next;
       	}

if (0) {

		# Update the files in /install/custom/netboot/AIX/syncfile to the root image
		# figure out the path of root image 
		my $cmd = "/usr/sbin/lsnim -a location $imagehash{$image_name}{root} | /usr/bin/grep location 2>/dev/null";
		my $location = xCAT::Utils->runcmd("$cmd", -1);
		$location =~ s/\s*location = //;
		chomp($location);
		my $root_location = $location.'/'.$nim_name.'/';
		if (-d $root_location) {
			my $syncfile = $$node_syncfile{$node};
xCAT::MsgUtils->message("S", "mkdsklsnode: $root_location, $syncfile");

			my $arg = ["-i", "$root_location", "-F", "$syncfile"];
			my $env = ["RSYNCSN=yes", "DSH_RSYNC_FILE=$syncfile"];
			$subreq->({command=>['xdcp'], node=>[$node], arg=>$arg, env=>$env}, $callback);
		}

}



	} # end - for each node

	#
	# update the node definitions with the new osimage - if provided
	#
	my %nodeattrs;
	foreach my $node (keys %objhash) {
        chomp $node;
        if (!grep(/^$node$/, @nodesfailed)) {
            # change the node def if we were successful
            $nodeattrs{$node}{objtype} = 'node';
            $nodeattrs{$node}{os} = "AIX";
            if ($::OSIMAGE) {
                $nodeattrs{$node}{profile} = $::OSIMAGE;
            }
        }
    }
	if (xCAT::DBobjUtils->setobjdefs(\%nodeattrs) != 0) {
		my $rsp;
		push @{$rsp->{data}}, "$Sname: Could not write data to the xCAT database.\n";
		xCAT::MsgUtils->message("E", $rsp, $::callback);
		$error++;
	}

	# restart inetd
    if ($::VERBOSE) {
        my $rsp;
        push @{$rsp->{data}}, "Restarting inetd on $Sname.\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
    }
    my $scmd = "stopsrc -s inetd";
    my $output = xCAT::Utils->runcmd("$scmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not stop inetd on $Sname.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        $error++;
    }
    my $scmd = "startsrc -s inetd";
    my $output = xCAT::Utils->runcmd("$scmd", -1);
    if ($::RUNCMD_RC  != 0) {
        my $rsp;
        push @{$rsp->{data}}, "Could not start inetd on $Sname.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        $error++;
    }

	#
	# process any errors
	#
	if ($error) {
		my $rsp;
		push @{$rsp->{data}}, "$Sname: One or more errors occurred when attempting to initialize AIX NIM diskless nodes.\n";

		if ($::VERBOSE && (defined(@nodesfailed))) {
			push @{$rsp->{data}}, "$Sname: The following node(s) could not be initialized.\n";
			foreach my $n (@nodesfailed) {
				push @{$rsp->{data}}, "$n";
			}
		}

		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	} else {
		my $rsp;
		push @{$rsp->{data}}, "$Sname: AIX/NIM diskless nodes were initialized.\n";
		xCAT::MsgUtils->message("I", $rsp, $callback);

 		return 0;
	}

	return 0;
}

#----------------------------------------------------------------------------

=head3   checkNIMnetworks

		See if there is a NIM network definition for the networks these
			nodes are on.

		If not then create the NIM definitions etc.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Comments:

=cut

#-----------------------------------------------------------------------------
sub checkNIMnetworks
{
	my $callback = shift;
    my $nodes = shift;
    my $nethash = shift;

    my @nodelist = @{$nodes};
    my %nethash; 	# hash of xCAT network definitions for each node
    if ($nethash) {
        %nethash = %{$nethash};
    }

	#
    # get all the nim network names and attrs defined on this SN
	#
	my $cmd = qq~/usr/sbin/lsnim -c networks | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
    my @networks = xCAT::Utils->runcmd("$cmd", -1);
	
	# for each NIM network - get the attrs
	my %NIMnets;
	foreach my $netwk (@networks) {
		my $cmd = qq~/usr/sbin/lsnim -Z -a net_addr -a snm $netwk 2>/dev/null~;
		my @result = xCAT::Utils->runcmd("$cmd", -1);
		if ($::RUNCMD_RC  != 0) {
			my $rsp;
			push @{$rsp->{data}}, "Could not run lsnim command: \'$cmd\'.\n";
			xCAT::MsgUtils->message("E", $rsp, $callback);
			return 1;
		}

		foreach my $l (@result){
			# skip comment lines
			next if ($l =~ /^\s*#/);

			my ($nimname, $net_addr, $snm) = split(':', $l);
			$NIMnets{$netwk}{'net_addr'} = $net_addr;
            $NIMnets{$netwk}{'snm'} = $snm;
		}
	}

	#
    # for each node - see if the net we need is defined
	#
	foreach my $node (@nodelist) {
		# see if the NIM net we need is defined

		# split node mask
		my ($nm1, $nm2, $nm3, $nm4) = split('\.', $nethash{$node}{mask});

		# split node net addr
		my ($nn1, $nn2, $nn3, $nn4) = split('\.', $nethash{$node}{net});

		my $foundmatch=0;
		# foreach nim network name
		foreach my $netwk (@networks) {

			# split definition mask
			my ($dm1, $dm2, $dm3, $dm4) = split('\.', $NIMnets{$netwk}{'snm'});

			# split definition net addr
			my ($dn1, $dn2, $dn3, $dn4) = split('\.', $NIMnets{$netwk}{'net_addr'});
			# check for the same netmask and network address
			if ( ($nn1 == $dn1) && ($nn2 ==$dn2) && ($nn3 == $dn3) && ($nn4 == $dn4) ) {
				if ( ($nm1 == $dm1) && ($nm2 ==$dm2) && ($nm3 == $dm3) && ($nm4 == $dm4) ) {
					$foundmatch=1;
				}
			}
		}

		# if not defined then define it! 
		if (!$foundmatch) {

			# create new nim network def
			# use the same network name as xCAT uses
			my $cmd = qq~/usr/sbin/nim -o define -t ent -a net_addr=$nethash{$node}{net} -a snm=$nethash{$node}{mask} -a routing1='default $nethash{$node}{gateway}' $nethash{$node}{netname} 2>/dev/null~;

			my $output1 = xCAT::Utils->runcmd("$cmd", -1);
			if ($::RUNCMD_RC  != 0) {
				my $rsp;
				push @{$rsp->{data}}, "Could not run \'$cmd\'.\n";
				xCAT::MsgUtils->message("E", $rsp, $callback);
				return 1;
			}

			#
        	# create an interface def (if*) for the master 
			#
			# first get the if* and cable_type* attrs
			#  - the -A option gets the next avail index for this attr
			my $ifcmd = qq~/usr/sbin/lsnim -A if master 2>/dev/null~;
			my $ifindex = xCAT::Utils->runcmd("$ifcmd", -1);
            if ($::RUNCMD_RC  != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Could not run \'$ifcmd\'.\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }

			my $ctcmd = qq~/usr/sbin/lsnim -A cable_type master 2>/dev/null~;
			my $ctindex = xCAT::Utils->runcmd("$ctcmd", -1);
			if ($::RUNCMD_RC  != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Could not run \'$ctcmd\'.\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }

			# get the local adapter hostname for this network
			# get all the possible IPs for the node I'm running on
			my $ifgcmd = "ifconfig -a | grep 'inet '";
			my @result = xCAT::Utils->runcmd($ifgcmd, 0);
			if ($::RUNCMD_RC != 0) {
				my $rsp;
                push @{$rsp->{data}}, "Could not run \'$ifgcmd\'.\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
			}

			my $adapterhostname;
			foreach my $int (@result) {
				my ($inet, $myIP, $str) = split(" ", $int);
				chomp $myIP;

				# split interface IP
				my ($h1, $h2, $h3, $h4) = split('\.', $myIP);

				# split mask 
				my ($m1, $m2, $m3, $m4) = split('\.', $nethash{$node}{mask});

				# split net address 
				my ($n1, $n2, $n3, $n4) = split('\.', $nethash{$node}{net});

				# AND this interface IP with the netmask of the network
				my $a1 = ((int $h1) & (int $m1));
				my $a2 = ((int $h2) & (int $m2));
				my $a3 = ((int $h3) & (int $m3));
				my $a4 = ((int $h4) & (int $m4));

				# if all the octals match the network addr then we have 
				#	the right interface
				if ( ($n1 == $a1) && ($n2 ==$a2) && ($n3 == $a3) && ($n4 == $a4) ) {
					my $packedaddr = inet_aton($myIP);
					$adapterhostname = gethostbyaddr($packedaddr, AF_INET);
					last;
				}
			}

			# define the new interface
			my $chcmd = qq~/usr/sbin/nim -o change -a if$ifindex='$nethash{$node}{netname} $adapterhostname 0' -a cable_type$ctindex=N/A master 2>/dev/null~;

			my $output2 = xCAT::Utils->runcmd("$chcmd", -1);
            if ($::RUNCMD_RC  != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Could not run \'$chcmd\'.\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }

        	# get the next index for the routing attr
			my $ncmd = qq~/usr/sbin/lsnim -A routing master_net 2>/dev/null~;
			my $rtindex = xCAT::Utils->runcmd("$ncmd", -1);
			if ($::RUNCMD_RC  != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Could not run \'$ncmd\'.\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }

			# get hostname of primary int - always if1
			my $hncmd = qq~/usr/sbin/lsnim -a if1 -Z master 2>/dev/null~;
			my $ifone = xCAT::Utils->runcmd("$hncmd", -1);
			if ($::RUNCMD_RC  != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Could not run \'$hncmd\'.\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }

			my ($junk1, $junk2, $adapterhost) = split(':', $ifone);
			#my $adapterIP = inet_ntoa(inet_aton($adapterhost));

			# create static routes between the networks
			my $rtgcmd = qq~/usr/sbin/nim -o change -a routing$rtindex='master_net $nethash{$node}{gateway} $adapterhost' $nethash{$node}{netname} 2>/dev/null~;
			my $output3 = xCAT::Utils->runcmd("$rtgcmd", -1);
            if ($::RUNCMD_RC  != 0) {
                my $rsp;
                push @{$rsp->{data}}, "Could not run \'$rtgcmd\'.\n";
                xCAT::MsgUtils->message("E", $rsp, $callback);
                return 1;
            }

		} # end - define new nim network

	} # end - for each node

	return 0;
}

#----------------------------------------------------------------------------

=head3   make_SN_resource 

		See if the required NIM resources are created on the local server.
		
		Create local definitions if necessary.

		Runs only on service nodes that are not the NIM primary

		Supports the following NIM resources:
		 	bosinst_data, dump, home, mksysb,
            installp_bundle, lpp_source, script, paging
            root, shared_home, spot, tmp, resolv_conf

		Also does the NIM setup for additional networks if necessary.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Comments:

=cut

#-----------------------------------------------------------------------------
sub make_SN_resource
{
	my $callback = shift;
	my $nodes = shift;
	my $images = shift;
	my $imghash = shift;
	my $lhash = shift;
	my $nethash = shift;

	my @nodelist = @{$nodes};
	my @image_names = @{$images};
	my %imghash; # hash of osimage defs
	my %lochash; # hash of res locations
	my %nethash;
	if ($imghash) {
		%imghash = %{$imghash};
	}
	if ($lhash) {
		%lochash = %{$lhash};
	}
	if ($nethash) {
		%nethash = %{$nethash};
	}

	my $cmd;
	
	my $SNname = &myxCATname();
	chomp $SNname;

	my $nimprime = &getnimprime();
    chomp $nimprime;

	#
    #  Install/config NIM master if needed
    #
	my $lsnimcmd = "/usr/sbin/lsnim -l >/dev/null 2>&1";
    my $out = xCAT::Utils->runcmd("$lsnimcmd", -1);
    if ($::RUNCMD_RC  != 0) {

		# then we need to configure NIM on this node
		if ($::VERBOSE) {
			my $rsp;
			push @{$rsp->{data}}, "Configuring NIM.\n";
			xCAT::MsgUtils->message("I", $rsp, $callback);
		}

        #  NIM filesets should already be installed on the service node
        my $nimcmd = "nim_master_setup -a mk_resource=no";
        if ($::VERBOSE) {
            my $rsp;
            push @{$rsp->{data}}, "Running: \'$nimcmd\'\n";
            xCAT::MsgUtils->message("I", $rsp, $callback);
        }
		my $nimout = xCAT::Utils->runcmd("$nimcmd", -1);
        if ($::RUNCMD_RC  != 0) {
            my $rsp;
            push @{$rsp->{data}}, "Could not install and configure NIM.\n";
            if ($::VERBOSE) {
                push @{$rsp->{data}}, "$nimout";
            }
            xCAT::MsgUtils->message("E", $rsp, $callback);
            return 1;
        }
    }

	# make sure we have the NIM networks defs etc we need for these nodes
	if (&checkNIMnetworks($callback, \@nodelist, \%nethash) != 0) {
		return 1;
	}

	#
	# get list of valid NIM resource types from local NIM 
	#
	$cmd = qq~/usr/sbin/lsnim -P -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
	my @nimrestypes = xCAT::Utils->runcmd("$cmd", -1);
    if ($::RUNCMD_RC  != 0)
    {
        my $rsp;
        push @{$rsp->{data}}, "Could not get NIM resource types on \'$SNname\'.\n";
        xCAT::MsgUtils->message("E", $rsp, $callback);
        return 1;
    }

	#
	# get the local defined res names
	#
	$cmd = qq~/usr/sbin/lsnim -c resources | /usr/bin/cut -f1 -d' ' 2>/dev/null~;
	my @nimresources = xCAT::Utils->runcmd("$cmd", -1);
	if ($::RUNCMD_RC  != 0) {
		my $rsp;
		push @{$rsp->{data}}, "Could not get NIM resource definitions on \'$SNname\'.\n";
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}

	#
	# go through each osimage needed on this server 
	#	- if the NIM resource is not already defined then define it
	#

	# for each image
	foreach my $image (@image_names) {
		my @orderedtypelist;
		# always do lpp 1st, spot 2nd, rest after that
		#   ex. shared_root requires spot
		if ($imghash{$image}{lpp_source} ) {
    		push (@orderedtypelist, 'lpp_source');
		}
		if ($imghash{$image}{spot} ) {
    		push (@orderedtypelist, 'spot');
		}
		foreach my $restype (keys (%{$imghash{$image}})) {
    		if ( ($restype ne 'lpp_source') && ($restype ne 'spot')) {
        		push (@orderedtypelist, $restype);
    		}
		}

		# for each resource
		foreach my $restype (@orderedtypelist) {

			# if a valid NIM type and a value is set
			if (($imghash{$image}{$restype}) && (grep(/^$restype$/, @nimrestypes))) {

				#  Note: - for now keep it simple - if the resource exists
                #   then don't try to recreate it

				#  see if it already exists on this SN
				# if (grep(/^$imghash{$image}{$restype}$/, @nimresources)) 
				if (0) 
				{
					# is it allocated?
					my $cmd = "/usr/sbin/lsnim -l $imghash{$image}{$restype} 2>/dev/null";
					my @result = xCAT::Utils->runcmd("$cmd", -1);
					if ($::RUNCMD_RC  != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not run lsnim command: \'$cmd\'.\n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
						next;
					}

					my $alloc_count;
					foreach (@result){
						my ($attr,$value) = split('=');
						chomp $attr;
						$attr =~ s/\s*//g;  # remove blanks
						chomp $value;
						$value =~ s/^\s*//;
						if ($attr eq "alloc_count") {
							$alloc_count = $value;
							last;
						}
					}

					if ( defined($alloc_count) && ($alloc_count != 0) ){
						my $rsp;
						push @{$rsp->{data}}, "The resource named \'$imghash{$image}{$restype}\' is currently allocated. It will not be recreated.\n";
						xCAT::MsgUtils->message("I", $rsp, $callback);
						next;
					} else {
						# it's not allocated so remove and recreate
						my $cmd = "nim -Fo remove $imghash{$image}{$restype}";
						my $output = xCAT::Utils->runcmd("$cmd", -1);
						if ($::RUNCMD_RC  != 0) {
							my $rsp;
							push @{$rsp->{data}}, "Could not remove the NIM resource definition \'$imghash{$image}{$restype}\'.\n";
							push @{$rsp->{data}}, "$output";
							xCAT::MsgUtils->message("E", $rsp, $callback);
							next;
						}
					}
				}
	
				#  see if it already exists on this SN
                if (grep(/^$imghash{$image}{$restype}$/, @nimresources)) {
                    my $rsp;
                    push @{$rsp->{data}}, "Using existing resource called \'$imghash{$image}{$restype}\'.\n";
                    xCAT::MsgUtils->message("I", $rsp, $callback);
                    next;
                }

				# if root, shared_root, tmp, home, shared_home, dump, 
				#	paging then
				# 	these dont require copying anything from the nim primary
				my @dir_res=("root", "shared_root", "tmp", "home", "shared_home", "dump", "paging");
				if (grep(/^$restype$/, @dir_res) ) {

					my $loc = dirname(dirname($lochash{$imghash{$image}{$restype}}));
					chomp $loc;
					if (&mknimres($imghash{$image}{$restype}, $restype, $callback, $loc, $imghash{$image}{spot}) != 0) {
						next;
					}
				}

				# only make lpp_source for standalone type images				
				if (($restype eq "lpp_source" ) && ($imghash{$image}{"nimtype"} eq 'standalone')) {

					# restore the backup file - then remove it
					my $bkname = $imghash{$image}{$restype} . ".bk";

					my $resdir = $lochash{$imghash{$image}{$restype}};
					# ex. /install/nim/lpp_source/61D_lpp_source

					my $dir = dirname($resdir);
                    # ex. /install/nim/lpp_source
					if ($::VERBOSE) {
						my $rsp;
						push @{$rsp->{data}}, "Restoring $bkname on $SNname. Running command \'mv $dir/$bkname $resdir/$bkname; cd $resdir; restore -xvqf $bkname; rm $bkname\'.\n";
						xCAT::MsgUtils->message("I", $rsp, $callback);
					}
					my $restcmd = "mv $dir/$bkname $resdir/$bkname; cd $resdir; restore -xvqf $bkname; rm $bkname";
					my $output = xCAT::Utils->runcmd("$restcmd", -1);
					if ($::RUNCMD_RC  != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not restore NIM resource backup file called \'$bkname\'.\n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
					}

					# define the local res
					my $cmd = "/usr/sbin/nim -Fo define -t lpp_source -a server=master -a location=$lochash{$imghash{$image}{$restype}} $imghash{$image}{$restype}";
					my $output = xCAT::Utils->runcmd("$cmd", -1);
					if ($::RUNCMD_RC  != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not create NIM resource $imghash{$image}{$restype} on $SNname \n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
					}
				}

				# if installp_bundle or script they could have multiple names
				#		so the imghash name must be split 
				#  the lochash is based on names 
				if (($restype eq "installp_bundle") || ($restype eq "script") ) {
					foreach my $res (split /,/, $imghash{$image}{$restype}) {
						# if the resource is not defined on the SN
						if (!grep(/^$res$/, @nimresources)) {

							# define the local resource
							my $cmd = "/usr/sbin/nim -Fo define -t $restype -a server=master -a location=$lochash{$res}  $res";

							my $output = xCAT::Utils->runcmd("$cmd", -1);
							if ($::RUNCMD_RC  != 0) {
								my $rsp;
								push @{$rsp->{data}}, "Could not create NIM resource $res on $SNname \n";
								xCAT::MsgUtils->message("E", $rsp, $callback);
							}
						}
					}
				}

				# if mksysb, resolv_conf, bosinst_data  then
				#   the last part of the location is the actual file name
				# 	but not necessarily the resource name! 
				my @usefileloc = ("mksysb", "resolv_conf", "bosinst_data");
				if (grep(/^$restype$/, @usefileloc) ) {

					# define the local resource
					my $cmd = "/usr/sbin/nim -Fo define -t $restype -a server=master -a location=$lochash{$imghash{$image}{$restype}} $imghash{$image}{$restype}";
					my $output = xCAT::Utils->runcmd("$cmd", -1);
					if ($::RUNCMD_RC  != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not create NIM resource $imghash{$image}{$restype} on $SNname \n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
					}
				}

				# if spot 
				if ($restype eq "spot" ) {

					my $rsp;
					push @{$rsp->{data}}, "Creating a SPOT resource on $SNname.  This could take a while.\n";
					xCAT::MsgUtils->message("I", $rsp, $callback);

					# restore the backup file - then remove it
                    my $bkname = $imghash{$image}{$restype} . ".bk";
					my $resdir = dirname($lochash{$imghash{$image}{$restype}});
					chomp $resdir;
                    # ex. /install/nim/spot/612dskls

					my $dir = dirname($resdir);
					# ex. /install/nim/spot

					if ($::VERBOSE) {
                        my $rsp;
                        push @{$rsp->{data}}, "Restoring $bkname on $SNname. Running command \'mv $dir/$bkname $resdir/$bkname; cd $resdir; restore -xvqf $bkname; rm $bkname\'\n";
						xCAT::MsgUtils->message("I", $rsp, $callback);
					}
						
					my $restcmd = "mv $dir/$bkname $resdir/$bkname; cd $resdir; restore -xvqf $bkname; rm $bkname";

					my $output = xCAT::Utils->runcmd("$restcmd", -1);
					if ($::RUNCMD_RC  != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not restore NIM resource backup file called \'$bkname\'.\n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
					}

					# location for spot is odd
					# ex. /install/nim/spot/611image/usr
					# want /install/nim/spot for loc when creating new one
					my $loc = dirname(dirname($lochash{$imghash{$image}{$restype}}));
					chomp $loc;

					my $spotcmd = "/usr/lpp/bos.sysmgt/nim/methods/m_mkspot -o -a server=master -a location=$loc -a source=no $imghash{$image}{$restype}";

					if ($::VERBOSE) {
                        my $rsp;
                        push @{$rsp->{data}}, "Running: \'$spotcmd\'\n";
                        xCAT::MsgUtils->message("I", $rsp, $callback);
                    }
					
					my $output = xCAT::Utils->runcmd("$spotcmd", -1);
					if ($::RUNCMD_RC  != 0) {
						my $rsp;
						push @{$rsp->{data}}, "Could not create NIM resource $imghash{$image}{$restype} on $SNname \n";
						xCAT::MsgUtils->message("E", $rsp, $callback);
					}
				} # end  - if spot
			} # end - if valid NIM res type
		} # end - for each restype in osimage def
	} # end - for each image

	return 0;
}

#----------------------------------------------------------------------------

=head3   prermdsklsnode

        Preprocessing for the mkdsklsnode command.

        Arguments:
        Returns:
                0 - OK
                1 - error
				2 - done processing this cmd
        Comments:
=cut

#-----------------------------------------------------------------------------
sub prermdsklsnode
{
	my $callback = shift;

    if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
        &rmdsklsnode_usage($callback);
        return 2;
    }

	# parse the options
    if(!GetOptions(
        'f|force'   => \$::FORCE,
        'h|help'     => \$::HELP,
        'i=s'       => \$::opt_i,
        'verbose|V' => \$::VERBOSE,
        'v|version'  => \$::VERSION,))
    {
        &rmdsklsnode_usage($callback);
        return 1;
    }

    if ($::HELP) {
        &rmdsklsnode_usage($callback);
        return 2;
    }

	# display the version statement if -v or --verison is specified
    if ($::VERSION)
    {
        my $version=xCAT::Utils->Version();
        my $rsp;
        push @{$rsp->{data}}, "rmdsklsnode $version\n";
        xCAT::MsgUtils->message("I", $rsp, $callback);
        return 2;
    }

	return 0;
}

#----------------------------------------------------------------------------

=head3   rmdsklsnode

        Support for the rmdsklsnode command.

		Remove NIM diskless client definitions.

        Arguments:
        Returns:
                0 - OK
                1 - error
        Comments:

			rmdsklsnode [-V] [-f | --force] {-i image_name} noderange
=cut

#-----------------------------------------------------------------------------
sub rmdsklsnode
{
	my $callback = shift;
	my $nodes = shift;
    my @nodelist = @$nodes;

	# To-Do
    # some subroutines require a global callback var
    #   - need to change to pass in the callback
    #   - just set global for now
    $::callback=$callback;

	if (defined(@{$::args})) {
        @ARGV = @{$::args};
    } else {
        &rmdsklsnode_usage($callback);
        return 2;
    }

	my $Sname = &myxCATname();
	chomp $Sname;

    # parse the options
    if(!GetOptions(
        'f|force'   => \$::FORCE,
        'h|help'     => \$::HELP,
        'i=s'       => \$::opt_i,
        'verbose|V' => \$::VERBOSE,
        'v|version'  => \$::VERSION,))
    {
        &rmdsklsnode_usage($callback);
        return 1;
    }

	if (!defined(@nodelist) ) {
		# error - must have list of nodes
		&rmdsklsnode_usage($callback);
		return 1;
	}

	# for each node
	my @nodesfailed;
	my $error;
	foreach my $node (@nodelist) {

		my $nodename;
		my $name;
		($name = $node) =~ s/\..*$//; # always use short hostname
		$nodename = $name;
		if ($::opt_i) {
			$nodename=$name . "_" . $::opt_i;
		}

		# nim -Fo reset c75m5ihp05_53Lcosi
		my $cmd = "nim -Fo reset $nodename  >/dev/null 2>&1";
		my $output;

    	$output = xCAT::Utils->runcmd("$cmd", -1);
    	if ($::RUNCMD_RC  != 0)
		{
			my $rsp;
			if ($::VERBOSE) {
				push @{$rsp->{data}}, "Could not remove the NIM machine definition \'$nodename\'.\n";
				push @{$rsp->{data}}, "$output";
			}
			xCAT::MsgUtils->message("E", $rsp, $callback);
			$error++;
			push(@nodesfailed, $nodename);
			next;
		}

		$cmd = "nim -Fo deallocate -a subclass=all $nodename  >/dev/null 2>&1";

    	$output = xCAT::Utils->runcmd("$cmd", -1);
    	if ($::RUNCMD_RC  != 0)
		{
			my $rsp;
			if ($::VERBOSE) {
				push @{$rsp->{data}}, "Could not remove the NIM machine definition \'$nodename\'.\n";
				push @{$rsp->{data}}, "$output";
			}
			xCAT::MsgUtils->message("E", $rsp, $callback);
			$error++;
			push(@nodesfailed, $nodename);
			next;
		}

		$cmd = "nim -Fo remove $nodename  >/dev/null 2>&1";

    	$output = xCAT::Utils->runcmd("$cmd", -1);
    	if ($::RUNCMD_RC  != 0)
		{
			my $rsp;
			if ($::VERBOSE) {
				push @{$rsp->{data}}, "Could not remove the NIM machine definition \'$nodename\'.\n";
				push @{$rsp->{data}}, "$output";
			}
			xCAT::MsgUtils->message("E", $rsp, $callback);
			$error++;
			push(@nodesfailed, $nodename);
			next;
		}

	} # end - for each node

	if ($error) {
		my $rsp;
		push @{$rsp->{data}}, "The following NIM machine definitions could NOT be removed.\n";
		
		foreach my $n (@nodesfailed) {
			push @{$rsp->{data}}, "$n";
		}
		xCAT::MsgUtils->message("E", $rsp, $callback);
		return 1;
	}
	return 0;
}

#----------------------------------------------------------------------------

=head3  mkdsklsnode_usage

=cut

#-----------------------------------------------------------------------------

sub mkdsklsnode_usage
{
	my $callback = shift;

	my $rsp;
	push @{$rsp->{data}}, "\n  mkdsklsnode - Use this xCAT command to define and initialize AIX \n\t\t\tdiskless nodes.";
	push @{$rsp->{data}}, "  Usage: ";
	push @{$rsp->{data}}, "\tmkdsklsnode [-h | --help ]";
	push @{$rsp->{data}}, "or";
	push @{$rsp->{data}}, "\tmkdsklsnode [-V] [-f|--force] [-n|--newname] \n\t\t[-i image_name] noderange [attr=val [attr=val ...]]\n";
	xCAT::MsgUtils->message("I", $rsp, $callback);
    return 0;
}

#----------------------------------------------------------------------------

=head3  rmdsklsnode_usage

=cut

#-----------------------------------------------------------------------------
sub rmdsklsnode_usage
{
	my $callback = shift;

	my $rsp;
	push @{$rsp->{data}}, "\n  rmdsklsnode - Use this xCAT command to remove AIX/NIM diskless client definitions.";
	push @{$rsp->{data}}, "  Usage: ";
	push @{$rsp->{data}}, "\trmdsklsnode [-h | --help ]";
	push @{$rsp->{data}}, "or";
	push @{$rsp->{data}}, "\trmdsklsnode [-V] [-f|--force] {-i image_name} noderange";
	xCAT::MsgUtils->message("I", $rsp, $callback);
	return 0;
}


#----------------------------------------------------------------------------

=head3  mknimimage_usage

=cut

#-----------------------------------------------------------------------------
sub mknimimage_usage
{
	my $callback = shift;

	my $rsp;
    push @{$rsp->{data}}, "\n  mknimimage - Use this xCAT command to create AIX image definitions.";
    push @{$rsp->{data}}, "  Usage: ";
    push @{$rsp->{data}}, "\tmknimimage [-h | --help]";
    push @{$rsp->{data}}, "or";
	push @{$rsp->{data}}, "\tmknimimage [-V] [-f|--force] [-r|--sharedroot] [-l <location>]\n\t\t-s [image_source] [-i current_image] [-t nimtype] [-m nimmethod]\n\t\t[-n mksysbnode] [-b mksysbfile] osimage_name\n\t\t [attr=val [attr=val ...]]\n";
    xCAT::MsgUtils->message("I", $rsp, $callback);
    return 0;
}

#----------------------------------------------------------------------------

=head3  rmnimimage_usage

=cut

#-----------------------------------------------------------------------------
sub rmnimimage_usage
{
	my $callback = shift;

	my $rsp;
	push @{$rsp->{data}}, "\n  rmnimimage - Use this xCAT command to remove an image definition.";
	push @{$rsp->{data}}, "  Usage: ";
	push @{$rsp->{data}}, "\trmnimimage [-h | --help]";
	push @{$rsp->{data}}, "or";
	push @{$rsp->{data}}, "\trmnimimage [-V] [-f|--force] image_name\n";
	xCAT::MsgUtils->message("I", $rsp, $callback);
	return 0;
}

#----------------------------------------------------------------------------

=head3  nimnodecust_usage

=cut

#-----------------------------------------------------------------------------

sub nimnodecust_usage
{
    my $callback = shift;

	my $rsp;
    push @{$rsp->{data}}, "\n  nimnodecust - Use this xCAT command to customize AIX \n\t\t\tstandalone nodes.";
    push @{$rsp->{data}}, "  Usage: ";
    push @{$rsp->{data}}, "\tnimnodecust [-h | --help ]";
    push @{$rsp->{data}}, "or";
    push @{$rsp->{data}}, "\tnimnodecust [-V] [ -s lpp_source_name ]\n\t\t[-p packages] [-b installp_bundles] noderange [attr=val [attr=val ...]]\n";
    xCAT::MsgUtils->message("I", $rsp, $callback);
    return 0;

}

#----------------------------------------------------------------------------

=head3  nimnodeset_usage

=cut

#-----------------------------------------------------------------------------

sub nimnodeset_usage
{
    my $callback = shift;

    my $rsp;
    push @{$rsp->{data}}, "\n  nimnodeset - Use this xCAT command to initialize AIX \n\t\t\tstandalone nodes.";
    push @{$rsp->{data}}, "  Usage: ";
    push @{$rsp->{data}}, "\tnimnodeset [-h | --help ]";
    push @{$rsp->{data}}, "or";
    push @{$rsp->{data}}, "\tnimnodeset [-V] [-f|--force] [ -i osimage_name]\n\t\tnoderange [attr=val [attr=val ...]]\n";
    xCAT::MsgUtils->message("I", $rsp, $callback);
    return 0;
}

#----------------------------------------------------------------------------

=head3  getnimprime

	Get the name of the primary NIM master

    Returns:

			hostname - short hostname of primary NIM master
			undef	 - could not find primary NIM master
    Example:
    Comments:

=cut

#-----------------------------------------------------------------------------

sub  getnimprime
{

	# the primary NIM master is either specified in the site table
	# or it is the xCAT management node.

	my $nimprime = xCAT::Utils->get_site_Master();
	my $sitetab = xCAT::Table->new('site');
	(my $et) = $sitetab->getAttribs({key => "NIMprime"}, 'value');
	if ($et and $et->{value}) {
		$nimprime = $et->{value};
	}
	chomp $nimprime;

	my $hostname;
	if ($nimprime) {
		if ($nimprime =~ /\d+\.\d+\.\d+\.\d+/) {
			my $packedaddr = inet_aton($nimprime);
			$hostname = gethostbyaddr($packedaddr, AF_INET);
		} else {
			$hostname = $nimprime;
		}

		my $shorthost;
		($shorthost = $hostname) =~ s/\..*$//;
		chomp $shorthost;
		return $shorthost;
	} 

	return undef;
}

#----------------------------------------------------------------------------

=head3  myxCATname

	Gets the name of the node I'm running on - as known by xCAT


=cut

#-----------------------------------------------------------------------------

sub myxCATname
{
    my ($junk, $name);

	my $catcmd="cat myxcatpost_* | grep '^NODE='";
	my $output = xCAT::Utils->runcmd("$catcmd", -1);
	if ($::RUNCMD_RC != 0) {
		# if no match then just return hostname
    	$name = hostname();
	} else {
		($junk, $name) = split('=', $output);
	}

	my $shorthost;
    ($shorthost = $name) =~ s/\..*$//;
    chomp $shorthost;
    return $shorthost;
}

#----------------------------------------------------------------------------

=head3  is_me

	returns 1 if the hostname is the node I am running on

	Gets all the interfcaes defined on this node and sees if 
		any of them match the IP of the hostname passed in

    Arguments:
        none
    Returns:
        1 -  this is the node I am running on
        0 -  this is not the node I am running on
    Globals:
        none
    Error:
        none
    Example:
         if (&is_me(&somehostname)) { blah; }
    Comments:
        none


=cut

#-----------------------------------------------------------------------------

sub is_me
{
    my $name = shift;

	# convert to IP
	my $nameIP = inet_ntoa(inet_aton($name));
    chomp $nameIP;

	# split into octets
	my ($b1, $b2, $b3, $b4) = split /\./, $nameIP;

	# get all the possible IPs for the node I'm running on
    my $ifcmd = "ifconfig -a | grep 'inet '";
    my @result = xCAT::Utils->runcmd($ifcmd, 0);
    if ($::RUNCMD_RC != 0)
    {
		my $rsp;
	#	push @{$rsp->{data}}, "Could not run $ifcmd.\n";
    #    xCAT::MsgUtils->message("E", $rsp, $callback);
		return 0;
    }

    foreach my $int (@result)
    {
        my ($inet, $myIP, $str) = split(" ", $int);
		chomp $myIP;
		# Split the two ip addresses up into octets
    	my ($a1, $a2, $a3, $a4) = split /\./, $myIP;		

		if ( ($a1 == $b1) && ($a2 == $b2) && ($a3 == $b3) && ($a4 == $b4) ) {
			return 1;
		}		
    }
	return 0;
}

#----------------------------------------------------------------------------
=head3  getNodesetStates
       returns the nodeset state for the given nodes. The possible nodeset
           states are: diskless, dataless, standalone and undefined.
    Arguments:
        nodes  --- a pointer to an array of nodes
        states -- a pointer to a hash table. This hash will be filled by this
             function.  The key is the nodeset status and the value is a pointer
             to an array of nodes.
    Returns:
       (return code, error message)
=cut
#-----------------------------------------------------------------------------
sub getNodesetStates {
  my $noderef=shift;
  if ($noderef =~ /xCAT_plugin::aixinstall/) {
    $noderef=shift;
  }
  my @nodes=@$noderef;
  my $hashref=shift; 
  
  if (@nodes>0) {
    my $nttab = xCAT::Table->new('nodetype');
    my $nimtab = xCAT::Table->new('nimimage');
    if (! $nttab) { return (1, "Unable to open nodetype table.");}
    if (! $nimtab) { return (1, "Unable to open nimimage table.");}

    my %nimimage=();
    my $nttabdata=$nttab->getNodesAttribs(\@nodes,['node', 'profile']); 
    foreach my $node (@nodes) {
      my $tmp1=$nttabdata->{$node}->[0];
      my $stat;
      if ($tmp1) {
        my $profile=$tmp1->{profile};
        if ( ! exists($nimimage{$profile})) { 
          (my $tmp)=$nimtab->getAttribs({'imagename'=>$profile},'nimtype');
          if (defined($tmp)) { $nimimage{$profile} = $tmp->{nimtype}; }
          else { $nimimage{$profile}="undefined";}
        }
        $stat=$nimimage{$profile};
      } else {$stat="undefined";}
      if (exists($hashref->{$stat})) {
	  my $pa=$hashref->{$stat};
	  push(@$pa, $node);
      }
      else {
	  $hashref->{$stat}=[$node];
      }
    }
    $nttab->close();
    $nimtab->close();
  }
  return (0, "");
}

#-------------------------------------------------------------------------------

=head3   getNodesetState
       get current nodeset stat for the given node.
    Arguments:
        nodes -- node name.
    Returns:
       nodesetstate 

=cut

#-------------------------------------------------------------------------------
sub getNodesetState {
  my $node = shift;
  my $state="undefined";
  my $nttab = xCAT::Table->new('nodetype');
  my $nimtab = xCAT::Table->new('nimimage');
  if ($nttab && $nimtab) {
    my $tmp1 = $nttab->getNodeAttribs($node,['profile']);
    if ($tmp1 && $tmp1->{profile}) {
       my $profile=$tmp1->{profile};
       my $tmp2=$nimtab->getAttribs({'imagename'=>$profile},'nimtype');
        if (defined($tmp2)) { $state = $tmp2->{nimtype}; }
    }
    $nttab->close();
    $nimtab->close();
  }

  return $state;
}

1;
