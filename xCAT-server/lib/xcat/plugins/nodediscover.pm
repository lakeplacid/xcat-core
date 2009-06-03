#!/usr/bin/env perl
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::nodediscover;
use xCAT::Table;
use IO::Socket;
use strict;

use XML::Simple;
if ($^O =~ /^linux/i) {
	$XML::Simple::PREFERRED_PARSER='XML::Parser';
}
use Data::Dumper;
use POSIX "WNOHANG";
use Storable qw(freeze thaw);
use IO::Select;
use IO::Handle;
use xCAT::Utils;
use Sys::Syslog;


sub gethosttag {
   #This function tries to return a good hostname for a node based on the
   #network to which it is connected (by $netn or maybe $ifname)
   #heuristic:
   #if the client had a valid IP address from a dhcp server, that is used as key
   #once the matching network is found, and an explicit mapping defined, try that
   #next, try to see if the ip for the case where hostname==nodename is on this net, if so, return that
   #next, try to do nodename-ifname, return that if successful
   #next, repeat process for all networks that have the common mgtifname field
   #return undef for now if none of the above worked
   my $node = shift;
   my $netn = shift;
   my $ifname = shift;
   my $usednames = shift;
   my %netmap = %{xCAT::Utils::my_if_netmap()};
   my $mgtifname = $netmap{$netn};
   my $secondpass = 0;
   my $name = "";
   my $defhost = inet_aton($node);
   my $nettab = xCAT::Table->new('networks');
   my $defn="";
   my @netents = @{$nettab->getAllEntries()};
   my $pass;
   #TODO: mgtifname field will get trounced in hierarchical setup, use a live check to match accurately
   foreach (@netents) {
      if ($_->{net} eq $netn or ($mgtifname and $mgtifname eq $netmap{$_->{net}})) { #either is the network  or shares physical interface
         if ($_->{nodehostname}) { #Check for a nodehostname rule in the table
            my $left;
            my $right;
            ($left,$right) = split(/\//,$_->{nodehostname},2);
            $name = $node;
            $name =~ s/$left/$right/;
            if ($name and inet_aton($name)) { 
               if ($netn eq $_->{net} and not $usednames->{$name}) { return $name; } 
               #At this point, it could still be valid if block was entered due to mgtifname
               my $nnetn = inet_ntoa(pack("N",unpack("N",inet_aton($name)) & unpack("N",inet_aton($_->{mask}))));
               if ($nnetn eq $_->{net} and not $usednames->{$name}) { return $name; }
            }
            $name=""; #Still here, this branch failed
         }
         $defn="";
         if ($defhost) {
            $defn = inet_ntoa(pack("N",unpack("N",$defhost) & unpack("N",inet_aton($_->{mask}))));
         }
         if ($defn eq $_->{net} and not $usednames->{$node}) { #the default nodename is on this network
            return $node;
         }
         my $tentativehost = $node . "-".$ifname;
         my $tnh = inet_aton($tentativehost);
         if ($tnh) {
            my $nnetn = inet_ntoa(pack("N",unpack("N",$tnh) & unpack("N",inet_aton($_->{mask}))));
            if ($nnetn eq $_->{net} and not $usednames->{$tentativehost}) {
               return $tentativehost;
            }
         }
      }
   }
}

sub handled_commands {
  return {
    #discovered => 'chain:ondiscover',
    discovered => 'nodediscover',
  };
}
sub process_request {
  my $request = shift;
  my $callback = shift;
  my $doreq = shift;
  my $node = $request->{node}->[0];
  my $ip = $request->{'_xcat_clientip'};
  openlog("xCAT node discovery",'','local0');
  #First, fill in tables with data fields..
  if (defined($request->{mtm}) or defined($request->{serial})) {
    my $vpdtab = xCAT::Table->new("vpd",-create=>1);
    if ($request->{mtm}->[0]) {
      $vpdtab->setNodeAttribs($node,{mtm=>$request->{mtm}->[0]});
    }
    if ($request->{serial}) {
      $vpdtab->setNodeAttribs($node,{serial=>$request->{serial}->[0]});
    }
  }
  my $nrtab;
  if (defined($request->{arch})) {
    #Set the architecture in nodetype.  If 32-bit only x86 or ppc detected, overwrite.  If x86_64, only set if either not set or not an x86 family
    my $typetab=xCAT::Table->new("nodetype",-create=>1);
    if ($request->{arch}->[0] =~ /x86_64/) {
      (my $nent) = $typetab->getNodeAttribs($node,['arch']);
      unless ($nent and ($nent->{arch} =~ /x86/)) { #If already an x86 variant, do not change
         $typetab->setNodeAttribs($node,{arch=>$request->{arch}->[0]});
         #this check is so that if an admin explicitly declares a node 'x86', the 64 bit capability is ignored
      }
    } else {
      $typetab->setNodeAttribs($node,{arch=>$request->{arch}->[0]});
    }
    my $currboot='';
    $nrtab = xCAT::Table->new('noderes'); #Attempt to check and set if wrong the netboot method on discovery, if admin omitted
    (my $rent) = $nrtab->getNodeAttribs($node,['netboot']);
    if ($rent and $rent->{'netboot'}) {
       $currboot=$rent->{'netboot'};
    }
    if ($request->{arch}->[0] =~ /x86/ and $currboot !~ /pxe/) {
       $nrtab->setNodeAttribs($node,{netboot=>'pxe'});
    } elsif ($request->{arch}->[0] =~ /ppc/ and $currboot  !~ /yaboot/) {
       $nrtab->setNodeAttribs($node,{netboot=>'yaboot'});
    }
  }
  if (defined($request->{mac})) {
    my $mactab = xCAT::Table->new("mac",-create=>1);
    my @ifinfo;
    my $macstring = "";
    my %usednames;
    foreach (@{$request->{mac}}) {
       @ifinfo = split /\|/;
       if ($ifinfo[3]) {
          (my $ip,my $netbits) = split /\//,$ifinfo[3];
	  if ($ip =~ /\d+\.\d+\.\d+\.\d+/) {
	  	my $ipn = unpack("N",inet_aton($ip));
		my $mask = 2**$netbits-1<<(32-$netbits);
		my $netn = inet_ntoa(pack("N",$ipn & $mask));
		my $hosttag = gethosttag($node,$netn,@ifinfo[1],\%usednames);
		if ($hosttag) {
         (my $rent) = $nrtab->getNodeAttribs($node,['primarynic','nfsserver']);
         unless ($rent and $rent->{primarynic}) { #if primarynic not set, set it to this nic
            $nrtab->setNodeAttribs($node,{primarynic=>@ifinfo[1]});
         }
         unless ($rent and $rent->{nfsserver}) {
            $nrtab->setNodeAttribs($node,{nfsserver=>xCAT::Utils->my_ip_facing($hosttag)});
         }
         $usednames{$hosttag}=1;
		   $macstring .= $ifinfo[2]."!".$hosttag."|";
		} else {
         $macstring .= $ifinfo[2]."!*NOIP*|";
      }
	  }
       }
    }
    $mactab->setNodeAttribs($node,{mac=>$macstring});
    my %request = (
       command => ['makedhcp'],
       node => [$node]
    );
    $doreq->(\%request);
  }
  #TODO: mac table?  on the one hand, 'the' definitive interface was determined earlier...
  #Delete the state it was in to make it traverse destiny once agoin
  my $chaintab = xCAT::Table->new('chain');
  if ($chaintab) {
    $chaintab->setNodeAttribs($node,{currstate=>'',currchain=>''});
    $chaintab->close();
  }


  #now, notify the node to continue life
  my $sock = new IO::Socket::INET (
          PeerAddr => $ip,
          PeerPort => '3001',
          Timeout => '1',
          Proto => 'tcp'
    );
    unless ($sock) { syslog("err","Failed to notify $ip that it's actually $node."); return; } #Give up if the node won't hear of it.
    print $sock "restart";
    close($sock);
    syslog("info","$node has been discovered");
}

1;
