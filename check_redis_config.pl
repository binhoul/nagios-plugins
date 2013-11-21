#!/usr/bin/perl -T
# nagios: -epn
#
#  Author: Hari Sekhon
#  Date: 2013-11-17 21:08:10 +0000 (Sun, 17 Nov 2013)
#
#  http://github.com/harisekhon
#
#  License: see accompanying LICENSE file
#  

$DESCRIPTION = "Nagios Plugin to check a Redis server's config";

$VERSION = "0.1";

use strict;
use warnings;
BEGIN {
    use File::Basename;
    use lib dirname(__FILE__) . "/lib";
}
use HariSekhonUtils qw/:DEFAULT :regex/;
use Cwd 'abs_path';
use IO::Socket;

# REGEX
my @config_file_only = qw(
                           activerehashing
                           daemonize
                           databases
                           maxclients
                           pidfile
                           port
                           rdbcompression
                           slaveof
                           syslog-.*
                           vm-.*
                       );

my @running_conf_only = qw(
                            maxmemory.*
                       );

my $default_config = "/etc/redis.conf";
my $conf = $default_config;

$host = "localhost";

our $REDIS_DEFAULT_PORT = 6379;
our $port               = $REDIS_DEFAULT_PORT;

my $no_warn_extra     = 0;
my $no_warn_missing   = 0;

our %options = (
    "H|host=s"      => [ \$host,        "Redis Host to connect to (default: localhost)" ],
    "P|port=s"      => [ \$port,        "Redis Port to connect to (default: $REDIS_DEFAULT_PORT)" ],
    "p|password=s"  => [ \$password,    "Password to connect with (use if Redis is configured with requirepass)" ],
    "C|config=s"    => [ \$conf,        "Redis config file (default: $default_config)" ],
);

@usage_order = qw/host port password config/;
get_options();

$host       = validate_host($host);
$port       = validate_port($port);
$password   = validate_password($password) if $password;
validate_thresholds();

vlog2;
set_timeout();

vlog2 "reading redis config file";
my $fh = open_file $conf;
vlog3;
vlog3 "=====================";
vlog3 "  Redis config file";
vlog3 "=====================";
my %config;
my ($key, $value);
while(<$fh>){
    chomp;
    s/#.*//;
    next if /^\s*$/;
    s/^\s*//;
    s/\s*$//;
    debug "conf file:  $_";
    /^\s*([\w\.-]+)\s+(.+)$/ or quit "UNKNOWN", "unrecognized line in config file '$conf': '$_'. $nagios_plugins_support_msg";
    $key   = $1;
    $value = $2;
    if($key eq "dir"){
        $value = abs_path($2);
    }
    if($value =~ /^(\d+(?:\.\d+)?)([KMGTP]B)$/i){
        $value = expand_units($1, $2);
    }
    vlog3 "config:  $key = $value";
    if($key eq "save"){
        if(defined($config{$key})){
            $value = "$config{$key} $value";
        }
    }
    $config{$key} = $value;
}
vlog3 "=====================";
vlog3;

$status = "OK";

# API libraries don't support config command, using direct socket connect, will do protocol myself
#my $redis = connect_redis(host => $host, port => $port, password => $password) || quit "CRITICAL", "failed to connect to redis server '$hostport'";

vlog2 "getting running redis config from '$host:$port'";

my $ip = validate_resolvable($host);
vlog2 "resolved $host to $ip";

$/ = "\r\n";
vlog2 "connecting to redis server $ip:$port ($host)";
my $redis_conn = IO::Socket::INET->new (
                                    Proto    => "tcp",
                                    PeerAddr => $ip,
                                    PeerPort => $port,
                                    Timeout  => $timeout,
                                 ) or quit "CRITICAL", sprintf("Failed to connect to '%s:%s'%s: $!", $ip, $port, (defined($timeout) and ($debug or $verbose > 2)) ? " within $timeout secs" : "");

vlog2;
if($password){
    vlog2 "sending redis password";
    print $redis_conn "auth $password\r\n";
    my @output = <$redis_conn>;
    quit "CRITICAL", "auth failed, returned: " . join(" ", @output) if @output;
    vlog2;
}
print $redis_conn "config get *\r\n";
my $num_args = <$redis_conn>;
$num_args =~ /^\*(\d+)\r$/ or quit "CRITICAL", "unexpected response: $num_args";
$num_args = $1;
my ($key_bytes, $value_bytes);
my %running_config;;
vlog3 "========================";
vlog3 "  Redis running config";
vlog3 "========================";
foreach(my $i=0; $i < ($num_args / 2); $i++){
    $key_bytes  = <$redis_conn>;
    chomp $key_bytes;
    debug "key bytes:  $key_bytes";
    $key_bytes =~ /^\$(\d+)$/ or quit "UNKNOWN", "protocol error, invalid key bytes line received: $key_bytes";
    $key_bytes = $1;
    $key        = <$redis_conn>;
    chomp $key;
    debug "key:        $key";
    ($key_bytes eq length($key)) or quit "UNKNOWN", "protocol error, num bytes does not match length of argument for $key ($key_bytes bytes expected, got " . length($key) . ")";
    $value_bytes = <$redis_conn>;
    chomp $value_bytes;
    debug "data bytes: $value_bytes";
    $value_bytes =~ /^\$(-?\d+)$/ or quit "UNKNOWN", "protocol error, invalid data bytes line received: $value_bytes";
    $value_bytes = $1;
    if($value_bytes == -1){
        next;
    }
    $value       = <$redis_conn>;
    chomp $value;
    debug "data:       $value";
    ($value_bytes eq length($value)) or quit "UNKNOWN", "protocol error, num bytes does not match length of argument for $value ($value_bytes bytes expected, got " . length($value) . ")";
    vlog3 "running config:  $key=$value";
    $running_config{$key} = $value;
}
vlog3 "========================";

my @missing_config;
my @mismatched_config;
my @extra_config;
foreach my $key (sort keys %config){
    unless(defined($running_config{$key})){
        if(grep { $key =~ /^$_$/ } @config_file_only){
            vlog3 "skipping: $key (config file only)";
            next;
        } else {
            push(@missing_config, $key);
        }
        next;
    }
    unless($config{$key} eq $running_config{$key}){
        push(@mismatched_config, $key);
    }
}

foreach my $key (sort keys %running_config){
    unless(defined($config{$key})){
        if(grep { $key =~ /^$_$/ } @running_conf_only){
            vlog3 "skipping: $key (running config only)";
        } else {
            push(@extra_config, $key);
        }
    }
}

$msg = "";
if(@mismatched_config){
    critical;
    #$msg .= "mismatched config: ";
    foreach(sort @mismatched_config){
        $msg .= "$_ value mismatch '$config{$_}' in config vs '$running_config{$_}' live on server, ";
    }
}
if((!$no_warn_missing) and @missing_config){
    warning;
    $msg .= "config missing on running server: ";
    foreach(sort @missing_config){
        $msg .= "$_, ";
    }
    $msg =~ s/, $//;
    $msg .= ", ";
}
if((!$no_warn_extra) and @extra_config){
    warning;
    $msg .= "extra config found on running server: ";
    foreach(sort @extra_config){
        $msg .= "$_=$running_config{$_}, ";
    }
    $msg =~ s/, $//;
    $msg .= ", ";
}

$msg = sprintf("%d config values tested from config file '$conf', %s", scalar keys %config, $msg);
$msg =~ s/, $//;

quit $status, $msg;