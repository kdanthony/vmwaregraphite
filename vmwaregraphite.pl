#!/usr/bin/perl -w
# vmwaregraphite.pl
# 2014-04 - Kevin Anthony
#
# Collects performance counters from vcenter for all attached hosts and passes to graphite.
# Uses forks to process several requests in parallel for performance. Increasing above 5
# generally does not improve things if at all.
#
# Heavily based on viperformance.pl Copyright (c) 2007 VMware, Inc.  All rights reserved.

# Required modules:
#   VMware SDK Perl
#   Parallel::ForkManager
#   Time::HiRes

# Uses config file in ~/.visdkrc
# Uses credential store in ~/.vmware/credstore/vicredentials.xml
# If these aren't there you need to pass --username --password and --url or set the environment variables (VI_USERNAME, VI_PASSWORD, VI_URL)
# See https://www.vmware.com/support/developer/viperltoolkit/doc/perl_toolkit_guide_idx.html if you need more help

# Set to path for VMware Perl SDK
use lib "/Users/kanthony/Downloads/vmware-vsphere-cli-distrib/apps/";

my $graphite_host   = '192.168.2.211';
my $graphite_port   = 2003;
my $graphite_type   = 'tcp';
my $graphite_prefix = 'vmware';

use strict;
use warnings;

use Net::Graphite;
use Parallel::ForkManager;
use Time::HiRes qw(time);
use VMware::VIRuntime;
use VMware::VICredStore;
use AppUtil::HostUtil;
use AppUtil::VMUtil;

$Util::script_version = "1.0";

sub get_performance;

# No need to adjust these in most cases
our $interval    = 20;
our $samples     = 1;
our $instance;

Opts::parse();
#Opts::validate(\&validate);

our $graphite = Net::Graphite->new(
   host => $graphite_host,
   port => $graphite_port,
   trace => 1,
   proto => $graphite_type,
   timeout => 1,
   fire_and_forget => 0,
   path => 'vmware',
);

my $all_counters;

Util::connect();

# Run up to 5 children at once. Set to 0 to disable all forking
my $pm = Parallel::ForkManager->new( 5 );

# Fetch all HostSystems from SDK, limiting the property set
my $host_views = Vim::find_entity_views(
   view_type  => "HostSystem",
   properties => ['name'],
);

foreach my $hostview (@$host_views) {
   my $vmware_server = $hostview->name; 

   # Everything until the finish runs only in the child if the children count was not set to 0
   $pm->start and next; 

   Util::connect();

   my $host = Vim::find_entity_view(
      view_type  => "HostSystem",
      filter     => {
         'name' => $vmware_server
      },
      properties => [ 'name' ],
   );
   my $perfmgr_view = Vim::get_view(mo_ref => Vim::get_service_content()->perfManager);

   get_performance( $vmware_server, 'cpu', $host, $perfmgr_view );
   get_performance( $vmware_server, 'mem', $host, $perfmgr_view );
   get_performance( $vmware_server, 'net', $host, $perfmgr_view );
   #get_performance( $vmware_server, 'disk' );
   #get_performance( $vmware_server, 'sys' );

   Util::disconnect();
   $pm->finish;

}

$pm->wait_all_children;

Util::disconnect();

sub get_performance() {

   my ( $hostname, $countertype, $host, $perfmgr_view ) = @_;

   my $start = time();

   my $graphite_string = '';
   # Format the hostname for graphite by taking out any dots and replacing with underscore
   my $hostname_graphite = $hostname;
   $hostname_graphite =~ s/\./_/g;

   print $hostname . " - " . $countertype . "\n";

   if ( !defined( $host ) ) {
      print "Host $hostname not found\n";
      return;
   }
   
   my @perf_metric_ids = get_perf_metric_ids(
      perfmgr_view => $perfmgr_view,
      host         => $host,
      type         => $countertype,
   );
 
   my $perf_query_spec;

   $perf_query_spec = PerfQuerySpec->new( 
      entity     => $host,
      metricId   => @perf_metric_ids,
      format     => 'csv',
      intervalId => $interval,
      maxSample  => $samples,
   );

   my $perf_data;
   eval {
       $perf_data = $perfmgr_view->QueryPerf( querySpec => $perf_query_spec);
   };
   if ( $@ ) {
      if ( ref( $@ ) eq 'SoapFault' ) {
         if ( ref( $@->detail ) eq 'InvalidArgument' ) {
            print "Specified parameters are not correct\n";
         }
      }
      return;
   }
   if ( ! @$perf_data ) {
      print "Either Performance data not available for requested period or instance is invalid\n";
      return;
   }
   foreach ( @$perf_data ) {
      my $time_stamps = $_->sampleInfoCSV;

      # Decided against grabbing the time from the response
      #$time_stamps =~ m/,(.+)Z/;
      #my $timestamp = str2time( $1 );

      my $values = $_->value;
      foreach ( @$values ) {
         my $counterlabel = $all_counters->{$_->id->counterId}->nameInfo->label;
         $counterlabel =~ s/\s/_/g;
         my $value = $_->value;

         $graphite->send( 
            path  => $graphite_prefix . '.' . $hostname_graphite . "." . $countertype . "." . $counterlabel,
            value => $value,
            time  => time(),
         );
      }
   }
   my $elapsed = time() - $start;
   printf( "%.2fs - get_performance\n", $elapsed );
}

# Copyright (c) 2007 VMware, Inc.  All rights reserved.
sub get_perf_metric_ids {
   my %args         = @_;
   my $start        = time();
   my $perfmgr_view = $args{ perfmgr_view };
   my $entity       = $args{ host };
   my $type         = $args{ type };

   my $counters;
   my @filtered_list;
   my $perfCounterInfo = $perfmgr_view->perfCounter;
   my $availmetricid   = $perfmgr_view->QueryAvailablePerfMetric( 
      entity => $entity 
   );
   
   foreach ( @$perfCounterInfo ) {
      my $key = $_->key;
      $all_counters->{ $key } = $_;
      my $group_info = $_->groupInfo;
      if ( $group_info->key eq $type ) {
         $counters->{ $key } = $_;
      } 
   }
   
   foreach ( @$availmetricid ) {
      if ( exists $counters->{$_->counterId} ) {
         #push @filtered_list, $_;
         my $metric = PerfMetricId->new (
            counterId => $_->counterId,
            instance => ($instance || ''),
         );
         push @filtered_list, $metric;
      }
   }
   my $elapsed = time() - $start;
   printf( "%.2fs - get_perf_metric_ids\n", $elapsed );
   return \@filtered_list;
}

