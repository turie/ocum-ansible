#!/usr/bin/perl
use strict;
use Data::Dumper;
use Getopt::Long;
use YAML;
use NaServer;

use Log::Log4perl qw(:easy);

#####################################################################
# CONSTANTS
#####################################################################
my $CFG_FILE = '/opt/netapp/etc/ocum-state.yml';
#####################################################################

#####################################################################
# MAIN
#####################################################################

$ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = 0;

my %params;
GetOptions(
   # replication operation, one of
   # activate
   # resume_rep
   # deactivate
   'rep_op=s'     => \$params{'rep-op'},
   'force'        => \$params{'force'},
   'update_sm'    => \$params{'update_sm'},
   # Only needed if state can't be read from system, e.g. 1st time run
   'current_rep_state=s'   => \$params{'current-rep-state'},
) or die "Illegal args";

my $cfg_r = YAML::LoadFile($CFG_FILE);
Log::Log4perl->easy_init(
    {
        file   => '>>' . $cfg_r->{'ocum'}{'log_file_path'},
        level  => $ALL,                      #Levels: $OFF,$FATAL,$ERROR,$WARN,$INFO,$DEBUG,$TRACE,$ALL
        layout => "%d [%p] %c: %m%n"
        }
);

my $logger = Log::Log4perl->get_logger('MAIN');
$logger->info("############################ STARTED ####################");
$logger->info("Started with operation: " . $params{'rep-op'});

SWITCH: {
   $params{'rep-op'} =~  m/^activate$/i && do {
      rep_state_set_active($cfg_r, \%params);
      last  SWITCH;
   };

   $params{'rep-op'} =~  m/^deactivate$/i && do {
      rep_state_set_inactive($cfg_r, \%params);
      last  SWITCH;
   };

   $params{'rep-op'} =~  m/^resume_rep$/i && do {
      rep_state_resume_rep($cfg_r, \%params);
      last  SWITCH;
   };

   die "Illegal op: " . $params{'rep-op'};
}
$logger->info("############################ COMPLETED ####################");

exit(0);

#####################################################################
# FUNCTIONS
#####################################################################

sub rep_state_set_active{
   my ( $cfg_r, $params_r ) = @_;

   my ($package, $filename, $line, $subroutine) = caller(0);
   my $logger = Log::Log4perl->get_logger($subroutine);

   my $result;
   my $local_state   = $params{'current-rep-state'} ? $params{'current-rep-state'} : get_ocum_state('local', $cfg_r);

   if( $local_state =~ m/(^ACTIVE$)|(^REPLICATING$)/ && ! $params{'force'} ){
      # Write a warning and return, this doesn't make sense
      $logger->error("Attempt to set state to active when it's already active or replicating, use the --force option to override");
      return;
   }

   my $na_server = NaServer->new($cfg_r->{'storage'}{'local'}{'controller_name'},
                                 $cfg_r->{'storage'}{'local'}{'nmsdk_major_version'},
                                 $cfg_r->{'storage'}{'local'}{'nmsdk_minor_version'}
                                 );
   # Use certficate based auth
   #$na_server->set_style('CERTIFICATE');
   #$na_server->set_client_cert_and_key(
   #   $cfg_r->{'ocum'}{'pem_file_path'},
   #   $cfg_r->{'ocum'}{'key_file_path'}
   #);
   $na_server->set_style('LOGIN');
   $na_server->set_admin_user($cfg_r->{'storage'}{'local'}{'admin_user'}, $cfg_r->{'storage'}{'local'}{'admin_pw'});
   $na_server->set_vserver($cfg_r->{'storage'}{'local'}{'vserver_name'});
   $na_server->set_transport_type('HTTPS');
   $na_server->set_server_type('FILER');

   #---------------------------------------------------------------
   # 1st we have to get the controller side ready
   # Assume SVM DR relationships
   #---------------------------------------------------------------
   eval{
      $result = $na_server->snapmirror_get_destination(
         'destination-location'    => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                       . ':'
                                       . $cfg_r->{'storage'}{'local'}{'volume_name'},
      );
   };

   if ( $@ && !( $@ =~ m/entry doesn't exist/ ) ){
      $logger->error("failed to get snapmirror destination list: " . $@);
      die;
   }
   elsif( $@ ){
      $logger->error( "Expected snapmirror relationship doesn't exist" );
      return;
   }

   update_sm($cfg_r) if ( $params_r->{'update_sm'} );

   eval{
      $result = $na_server->snapmirror_break(
         'destination-location'    =>$cfg_r->{'storage'}{'local'}{'vserver_name'}
                                       . ':'
                                       . $cfg_r->{'storage'}{'local'}{'volume_name'},
      );
   };
   if ( $@ ){
      $logger->error("Failed to break snapmirror: " . $@);
      die;
   }

   eval{
      $result = $na_server->snapmirror_destroy(
         'destination-location'    => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                       . ':'
                                       . $cfg_r->{'storage'}{'local'}{'volume_name'},
         'source-location'          => $cfg_r->{'storage'}{'remote'}{'vserver_name'}
                                       . ':'
                                       . $cfg_r->{'storage'}{'remote'}{'volume_name'},
      );
   };
   if ( $@ ){
      $logger->error("Failed to destroy snapmirror: " . $@);
      die;
   }

   $logger->info("Searching for the latest snapshot to restore to");
   eval{
      $result = $na_server->snapshot_get_iter(
         'max-records'  => 255,
         'query'        => {
            'snapshot-info'   => {
               'name'   => $cfg_r->{'storage'}{'snapshot_pattern'},
               'volume'  => $cfg_r->{'storage'}{'local'}{'volume_name'},
            },
         },
      );
   };
   if ( $@ ){
      $logger->error("Failed to get snapshot list: " . $@);
      die;
   }

   if ( $result->{'num-records'} <= 0 ){
      $logger->error("Unable to find any snapshots to restore to: " . $@);
      return;
   }

   my $latest_snap_r = undef;
   foreach my $snap_r ( @{$result->{'attributes-list'}{'snapshot-info'}} ){
      if ( ! $latest_snap_r || ($latest_snap_r->{'access-time'} < $snap_r->{'access-time'}) ){
         $latest_snap_r = $snap_r;
      }
   }
   $logger->info("Will restore volume to the following snapshot: " . $latest_snap_r->{'name'});

   my $vserver_name = $na_server->get_vserver();
   $na_server->set_vserver($cfg_r->{'storage'}{'local'}{'vserver_name'});
   eval{
      $result = $na_server->snapshot_restore_volume(
         'snapshot'  => $latest_snap_r->{'name'},
         'volume'    => $cfg_r->{'storage'}{'local'}{'volume_name'},
         'force'     => 'true',
      );
   };
   if ( $@ ){
      $logger->error("Failed to restore volume to latest snapshot: " . $@);
      die;
   }

   eval{
      $result = $na_server->volume_modify_iter(
         'query'        => {
            'volume-attributes'  => {
               'volume-id-attributes'  => {
                  'name'   => $cfg_r->{'storage'}{'local'}{'volume_name'},
               },
            },
         },
         'attributes'  => {
            'volume-attributes'  => {
               'volume-export-attributes'  => {
                  'policy'   => $cfg_r->{'storage'}{'export_policy_name'},
               },
            },
         },
      );
   };
   if ( $@ ){
      $logger->error("Failed to update export policy on volume: " . $@);
      die;
   }

   eval{
      $result = $na_server->volume_mount(
            'junction-path' => $cfg_r->{'storage'}{'volume_junction_path'},
            'volume-name'   => $cfg_r->{'storage'}{'local'}{'volume_name'},
      );
   };
   if ( $@ ){
      $logger->error("unable to mount volume: " . $@);
      die;
   }

   $na_server->set_vserver($vserver_name);

   #---------------------------------------------------------------
   # Now that the volume is RW and NFS exported, we can get OCUM
   # started
   #---------------------------------------------------------------
   my @activation_commands = (
      '/usr/bin/systemctl enable opt-netapp-data.mount',
      '/usr/bin/systemctl start opt-netapp-data.mount',
      '/usr/bin/systemctl enable mysqld.service',
      '/usr/bin/systemctl start mysqld.service',
      '/usr/bin/systemctl enable ocie.service',
      '/usr/bin/systemctl start ocie.service',
      '/usr/bin/systemctl enable ocieau.service',
      '/usr/bin/systemctl start ocieau.service',
   );
   $logger->info("Starting required services");
   foreach my $cmd ( @activation_commands ){
      $logger->info("${cmd}");
      my @result = `${cmd} 2>&1`;
      if ( $? ){
         $logger->error("${cmd} failed: " . @result);
         die @result;
      }
   }
   #---------------------------------------------------------------
   # If possible, enable snapshots on the newly active volume
   #---------------------------------------------------------------
   $logger->info("Set state to ACTIVE");
   set_ocum_state('ACTIVE', $cfg_r);
}

sub rep_state_set_inactive{
   my ( $cfg_r ) = @_;

   my ($package, $filename, $line, $subroutine) = caller(0);
   my $logger = Log::Log4perl->get_logger($subroutine);

   my $local_state   = $params{'current-rep-state'} ? $params{'current-rep-state'} : get_ocum_state('local', $cfg_r);

   $logger->info("Disabling required services");
   my @deactivation_commands = (
      '/usr/bin/systemctl disable ocieau.service',
      '/usr/bin/systemctl stop ocieau.service',
      '/usr/bin/systemctl disable ocie.service',
      '/usr/bin/systemctl stop ocie.service',
      '/usr/bin/systemctl disable mysqld.service',
      '/usr/bin/systemctl stop mysqld.service',
      '/usr/bin/systemctl disable opt-netapp-data.mount',
      '/usr/bin/systemctl stop opt-netapp-data.mount',
   );
   foreach my $cmd ( @deactivation_commands ){
      $logger->info("${cmd}");
      my @result = `${cmd} 2>&1`;
      if ( $? ){
         $logger->error("${cmd} failed: ". @result);
         die @result;
      }
   }

   # Verify that /opt/netapp/data is now an empty directory

   #---------------------------------------------------------------
   # If possible, disable snapshots on the previously primary volume
   #---------------------------------------------------------------
   my $na_server = NaServer->new($cfg_r->{'storage'}{'local'}{'controller_name'},
                                 $cfg_r->{'storage'}{'local'}{'nmsdk_major_version'},
                                 $cfg_r->{'storage'}{'local'}{'nmsdk_minor_version'}
                                 );
   # Use certficate based auth
   #$na_server->set_style('CERTIFICATE');
   #$na_server->set_client_cert_and_key(
   #   $cfg_r->{'ocum'}{'pem_file_path'},
   #   $cfg_r->{'ocum'}{'key_file_path'},
   #);
   $na_server->set_style('LOGIN');
   $na_server->set_admin_user($cfg_r->{'storage'}{'local'}{'admin_user'}, $cfg_r->{'storage'}{'local'}{'admin_pw'});
   $na_server->set_vserver($cfg_r->{'storage'}{'local'}{'vserver_name'});

   $logger->info("Unmounting the volume on the controllers");
   eval{
      $na_server->volume_unmount(
                                 'volume-name' => $cfg_r->{'storage'}{'local'}{'volume_name'},
                                 'force'  => 'true',
      );
   };
   if ( $@ ){
      $logger->error("Unmount failed: " . $@);
      die;
   }

   $logger->info("Setting state to INACTIVE");
   set_ocum_state('INACTIVE', $cfg_r);
}

sub rep_state_resume_rep{
   my ( $cfg_r ) = @_;

   my ($package, $filename, $line, $subroutine) = caller(0);
   my $logger = Log::Log4perl->get_logger($subroutine);

   my $local_state   = $params{'current-rep-state'} ? $params{'current-rep-state'} : get_ocum_state('local', $cfg_r);

   if ( ! $local_state =~ m/^ACTIVE$/ ){
      $logger->error("Required OCUM state is ACTIVE, found ${local_state}, cannot continue");
      return;
   }

   my $na_server = NaServer->new($cfg_r->{'storage'}{'local'}{'controller_name'},
                                 $cfg_r->{'storage'}{'local'}{'nmsdk_major_version'},
                                 $cfg_r->{'storage'}{'local'}{'nmsdk_minor_version'}
                                 );
   #$na_server->set_style('CERTIFICATE');
   #$na_server->set_client_cert_and_key(
   #   $cfg_r->{'ocum'}{'pem_file_path'},
   #   $cfg_r->{'ocum'}{'key_file_path'},
   #);
   $na_server->set_style('LOGIN');
   $na_server->set_admin_user($cfg_r->{'storage'}{'local'}{'admin_user'}, $cfg_r->{'storage'}{'local'}{'admin_pw'});
   $na_server->set_vserver($cfg_r->{'storage'}{'local'}{'vserver_name'});
   #$na_server->vserver_stop('vserver-name' => $cfg_r->{'storage'}{'remote'}{'vserver_name'});

   #---------------------------------------------------------------
   # Don't forget snapmirror release, which has to be done
   # the same way that I did it for AAHS
   #
   # I do the release here because I may not have access to the
   # previously production controller until this is run.
   #---------------------------------------------------------------
   eval{
      $na_server->snapmirror_release(
         'destination-location'  => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                    . ':'
                                    . $cfg_r->{'storage'}{'local'}{'volume_name'},
         'source-location'       => $cfg_r->{'storage'}{'remote'}{'vserver_name'}
                                    . ':'
                                    . $cfg_r->{'storage'}{'remote'}{'volume_name'},
      );
   };

   if ( $@ ){
      $logger->error("Failed to release snapmirror snapshots");
      # Not going to die here because I can still re-establish rep
   }

   eval{
      $na_server->snapmirror_create(
         'destination-location'  => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                    . ':'
                                    . $cfg_r->{'storage'}{'local'}{'volume_name'},
         'source-location'       => $cfg_r->{'storage'}{'remote'}{'vserver_name'}
                                    . ':'
                                    . $cfg_r->{'storage'}{'remote'}{'volume_name'},
         'relationship-type'     => 'data_protection',
         'schedule'              => $cfg_r->{'storage'}{'local'}{'sm_schedule'},
         'policy'                => 'DPDefault',
      );
   };
   if ( $@ ){
      $logger->error("Failed to recreate snapmirror");
      die;
   }

   eval{
      $na_server->snapmirror_resync(
         'destination-location'  => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                    . ':'
                                    . $cfg_r->{'storage'}{'local'}{'volume_name'},
      );
   };
   if ( $@ ){
      $logger->error("Failed to resync snapmirror");
      die;
   }

   $logger->info("Setting OCUM state to REPLICATING");
   set_ocum_state('REPLICATING', $cfg_r);
}

sub set_ocum_state{
   my ( $new_state, $cfg_r ) = @_;

   my $state_file;
   open($state_file, '>', $cfg_r->{'ocum'}{'state_file_path'});
   print $state_file $new_state;
   close($state_file);
}

sub rm_snap{
   my ( $snap_r, $cluster_handle, $svm_name, $wfa_util ) = @_;

   my @args = (
      'set diag ; ' .
      'vserver config override "' .
      'snapshot delete -force true -ignore-owners true ' .
      '-volume ' . $snap_r->{'volume'} . ' ' .
      '-vserver ' . $svm_name . ' ' .
      '-snapshot ' . $snap_r->{'name'} . '"'
   );
   #-----------------------------------------------------------------
   # We need to check the expiry time otherwise the delete will fail
   #-----------------------------------------------------------------
   my $current_time = time();
   my $timeout = $current_time + 1*60;
   my $is_deleted = $FALSE;

   while ( ! $is_deleted && ($current_time < $timeout) ){
      eval{
         exec_system_cli($cluster_handle, @args);
      };
      $is_deleted = $TRUE if ( ! $@ );
      $wfa_util->sendLog('INFO', $@) if ( $@ );
      if ( $@ && $@ =~ m/has not expired or is locked/ ){
         $wfa_util->sendLog('INFO', "Waiting for expiry-time");
         $current_time = time();
         $is_deleted = $TRUE;
         sleep 1;
      }
      elsif( $@ && $@ =~ m/There are no entries matching your query/ ){
         $wfa_util->sendLog('INFO', "Tried to delete snap but failed to find it on SVM: " . $snap_r->{'vserver'} . '=>' . $snap_r->{'volume'} . ':' . $snap_r->{'name'});
         $is_deleted = $TRUE;
      }
      elsif( $@ ){
         $wfa_util->sendLog('INFO', 'Snapshot delete failed for unknown reason' );
         $wfa_util->sendLog('INFO', $@ );
         $is_deleted = $TRUE;
         sleep 1;
      }
   }

   $wfa_util->sendLog('INFO', "Timed out waiting for snapshot expiry-time for " . $snap_r->{'name'})
      unless ( $is_deleted );

   my %ss_filter = (
      'query'  => {
         'snapshot-info'   => {
            'name'      => $snap_r->{'name'},
            'vserver'   => $svm_name,
            'volume'    => $snap_r->{'volume'},

         }
      }
   );

   my $result;
   eval{
      $cluster_handle->snapshot_get_iter( %ss_filter );
   };
   die $@ if ( $@ );

   if ( $result->{'num-records'} != 0 ){
      $wfa_util->sendLog('INFO',  "Failed to remove snapshot: " . $svm_name . '//' . $snap_r->{'volume'} . ':' . $snap_r->{'name'} );
   }
}

sub exec_system_cli {
   my ($server, @args) = @_;
   my $api  = NaElement->new('system-cli');
   my $args = NaElement->new('args');

   foreach my $arg (@args) {
      $args->child_add_string('arg', $arg);
   }

   $api->child_add($args);

   my $out;
   eval{
      $out = $server->invoke_elem($api);
   };
   die $@ if ( $@ );

   if($out->results_status() ne 'passed'){
      die "Cli XML request failed to pass \n";
   }

   if($out->child_get_string('cli-result-value') ne '1'){
      die $out->child_get_string('cli-output')."\n";
   }

   return $out->{'children'}['content']->{'content'};
}


sub get_ocum_state{
   my ( $location, $cfg_r ) = @_;
   SWITCH: {
      $location =~ m/^local$/ && do {
         my $state_file;
         open($state_file, '<', $cfg_r->{'ocum'}{'state_file_path'})
            or die "Unable to open state file: $!";
         my @state = <$state_file>;
         close($state_file);
         return $state[0];
         last SWITCH;
      };

      $location =~ m/^remote/ && do {
         return;
         my $state_file;
         open($state_file, '<', $cfg_r->{'ocum'}{'state_file_path'})
            or die "Unable to open state file: $!";
         my @state = <$state_file>;
         close($state_file);
         return $state[0];
         last SWITCH;
      };

      die "Illegal location: ${location}";
   }
   return;
}


sub update_sm{
   my ( $cfg_r ) = @_;

   my ($package, $filename, $line, $subroutine) = caller(0);
   my $logger = Log::Log4perl->get_logger($subroutine);

   my $result;
   my $na_server = NaServer->new($cfg_r->{'storage'}{'local'}{'controller_name'},
                                 $cfg_r->{'storage'}{'local'}{'nmsdk_major_version'},
                                 $cfg_r->{'storage'}{'local'}{'nmsdk_minor_version'}
                                 );
   #$na_server->set_style('CERTIFICATE');
   #$na_server->set_client_cert_and_key(
   #   $cfg_r->{'ocum'}{'pem_file_path'},
   #   $cfg_r->{'ocum'}{'key_file_path'},
   #);
   $na_server->set_style('LOGIN');
   $na_server->set_admin_user($cfg_r->{'storage'}{'local'}{'admin_user'}, $cfg_r->{'storage'}{'local'}{'admin_pw'});
   $na_server->set_vserver($cfg_r->{'storage'}{'local'}{'vserver_name'});

   eval{
      $result = $na_server->snapmirror_abort(
         'destination-location'  => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                    . ':'
                                    . $cfg_r->{'storage'}{'local'}{'volume_name'},
      );
   };
   if ( $@ && !($@ =~ m/No transfer to abort/) ) {
      $logger->error("Failed to abort snapmirror: " . $@);
      die;
   }

   my $aborted       = 0;
   my $start_time    = time();
   my $timeout_secs  = 300;
   my $timed_out     = 0;
   do {
      eval{
         $result = $na_server->snapmirror_get(
            'destination-location'    => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                          . ':'
                                          . $cfg_r->{'storage'}{'local'}{'volume_name'},
         );
      };

      if ( $@ ) {
         $logger->error("Unable to get snapmirror status: " . $@ );
         die;
      }
      if ( $result->{'attributes'}{'snapmirror-info'}{'relationship-status'} eq 'idle' ){
         $aborted = 1;
      }
      $timed_out = 1 if ( time() > ($start_time + $timeout_secs) );
      sleep 1 unless ( $aborted || $timed_out );
   } while ( ! ($aborted || $timed_out) );

   if ( !$aborted && $timed_out ){
      $logger->error("Timed out waiting for snapmirror abort, will continue");
   }

   eval{
      $result = $na_server->snapmirror_update(
         'destination-location'  => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                    . ':'
                                    . $cfg_r->{'storage'}{'local'}{'volume_name'},
      );
   };

   my $idle       = 0;
   $start_time    = time();
   $timeout_secs  = 300;
   $timed_out     = 0;
   do {
      eval{
         $result = $na_server->snapmirror_get(
            'destination-location'    => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                          . ':'
                                          . $cfg_r->{'storage'}{'local'}{'volume_name'},
         );
      };

      if ( $@ ) {
         $logger->error("Unable to get snapmirror status: " . $@ );
         die;
      }
      if ( $result->{'attributes'}{'snapmirror-info'}{'relationship-status'} eq 'idle' ){
         $idle = 1;
      }
      $timed_out = 1 if ( time() > ($start_time + $timeout_secs) );
      sleep 1 unless ( $idle || $timed_out );
   } while ( ! ($idle || $timed_out) );

   if ( ! $idle && $timed_out ){
      $logger->error("Timed out waiting for snapmirror update");
      die;
   }

   eval{
      $result = $na_server->snapmirror_quiesce(
         'destination-location'    => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                       . ':'
                                       . $cfg_r->{'storage'}{'local'}{'volume_name'},
      );
   };
   if ( $@ ){
      $logger->error("Failed to quiesce snapmirror: " . $@);
      die;
   }

   my $quiesced   = 0;
   $start_time    = time();
   $timeout_secs  = 300;
   $timed_out     = 0;
   do {
      eval{
         $result = $na_server->snapmirror_get(
            'destination-location'    => $cfg_r->{'storage'}{'local'}{'vserver_name'}
                                          . ':'
                                          . $cfg_r->{'storage'}{'local'}{'volume_name'},
         );
      };

      if ( $@ ) {
         $logger->error("Unable to get snapmirror status: " . $@ );
         die;
      }
      if ( $result->{'attributes'}{'snapmirror-info'}{'relationship-status'} eq 'quiesced' ){
         $quiesced = 1;
      }
      $timed_out = 1 if ( time() > ($start_time + $timeout_secs) );
      sleep 1 unless ( $quiesced || $timed_out );
   } while ( ! ($quiesced || $timed_out) );

   if ( ! $quiesced && $timed_out ){
      $logger->error("Timed out waiting for snapmirror quiesce");
      die;
   }

   return;
}
