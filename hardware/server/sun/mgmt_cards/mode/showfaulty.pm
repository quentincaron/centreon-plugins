################################################################################
# Copyright 2005-2013 MERETHIS
# Centreon is developped by : Julien Mathis and Romain Le Merlus under
# GPL Licence 2.0.
# 
# This program is free software; you can redistribute it and/or modify it under 
# the terms of the GNU General Public License as published by the Free Software 
# Foundation ; either version 2 of the License.
# 
# This program is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A 
# PARTICULAR PURPOSE. See the GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License along with 
# this program; if not, see <http://www.gnu.org/licenses>.
# 
# Linking this program statically or dynamically with other modules is making a 
# combined work based on this program. Thus, the terms and conditions of the GNU 
# General Public License cover the whole combination.
# 
# As a special exception, the copyright holders of this program give MERETHIS 
# permission to link this program with independent modules to produce an executable, 
# regardless of the license terms of these independent modules, and to copy and 
# distribute the resulting executable under terms of MERETHIS choice, provided that 
# MERETHIS also meet, for each linked independent module, the terms  and conditions 
# of the license of that module. An independent module is a module which is not 
# derived from this program. If you modify this program, you may extend this 
# exception to your version of the program, but you are not obliged to do so. If you
# do not wish to do so, delete this exception statement from your version.
# 
# For more information : contact@centreon.com
# Authors : Quentin Garnier <qgarnier@merethis.com>
#
####################################################################################

package hardware::server::sun::mgmt_cards::mode::showfaulty;

use base qw(centreon::plugins::mode);

use strict;
use warnings;
use centreon::plugins::misc;
use centreon::plugins::statefile;

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new(package => __PACKAGE__, %options);
    bless $self, $class;
    
    $self->{version} = '1.0';
    $options{options}->add_options(arguments =>
                                { 
                                  "hostname:s"       => { name => 'hostname' },
                                  "username:s"       => { name => 'username' },
                                  "password:s"       => { name => 'password' },
                                  "timeout:s"        => { name => 'timeout', default => 30 },
                                  "memory"           => { name => 'memory' },
                                  "command-plink:s"  => { name => 'command_plink', default => 'plink' },
                                });
    $self->{statefile_cache} = centreon::plugins::statefile->new(%options);
    return $self;
}

sub check_options {
    my ($self, %options) = @_;
    $self->SUPER::init(%options);

    if (!defined($self->{option_results}->{hostname})) {
       $self->{output}->add_option_msg(short_msg => "Need to specify a hostname.");
       $self->{output}->option_exit(); 
    }
    if (!defined($self->{option_results}->{username})) {
       $self->{output}->add_option_msg(short_msg => "Need to specify a username.");
       $self->{output}->option_exit(); 
    }
    if (!defined($self->{option_results}->{password})) {
       $self->{output}->add_option_msg(short_msg => "Need to specify a password.");
       $self->{output}->option_exit(); 
    }
    
    if (defined($self->{option_results}->{memory})) {
        $self->{statefile_cache}->check_options(%options);
    }
}

sub run {
    my ($self, %options) = @_;

    ######
    # Command execution
    ######
    my $cmd_in = 'show -o table -level all /SP/faultmgmt';
    my $cmd = "echo '$cmd_in' | " . $self->{option_results}->{command_plink} . " -T -l '" . $self->{option_results}->{username} . "' -batch -pw '" . $self->{option_results}->{password} . "' " . $self->{option_results}->{hostname} . " 2>&1";
    my ($lerror, $stdout, $exit_code) = centreon::plugins::misc::backtick(
                                                 command => $cmd,
                                                 timeout => $self->{option_results}->{timeout},
                                                 wait_exit => 1
                                                 );
    $stdout =~ s/\r//g;
    if ($lerror <= -1000) {
        $self->{output}->output_add(severity => 'UNKNOWN', 
                                    short_msg => $stdout);
        $self->{output}->display();
        $self->{output}->exit();
    }
    if ($exit_code != 0) {
        $stdout =~ s/\n/ - /g;
        $self->{output}->output_add(severity => 'UNKNOWN', 
                                    short_msg => "Command error: $stdout");
        $self->{output}->display();
        $self->{output}->exit();
    }
  
    ######
    # Command treatment
    ######
    my ($otp1, $otp2) = split(/\Q$cmd_in\E\n/, $stdout);
    my $long_msg = $otp2;
    $long_msg =~ s/\|/~/mg;
    
    if (!defined($otp2) || $otp2 !~ /Target.*?Property.*?Value/mi) {
        $self->{output}->output_add(long_msg => $stdout);
        $self->{output}->output_add(severity => 'UNKNOWN', 
                                    short_msg => "Command '$cmd_in' problems (see additional info).");
        $self->{output}->display();
        $self->{output}->exit();
    }
    
    $self->{output}->output_add(long_msg => $long_msg);
    if (defined($self->{option_results}->{memory})) {
        $self->{statefile_cache}->read(statefile => 'cache_sun_mgmtcards_' . $self->{option_results}->{hostname}  . '_' .  $self->{mode});
        $self->{output}->output_add(severity => 'OK', 
                                    short_msg => "No new problems on system.");
    } else {
        $self->{output}->output_add(severity => 'OK', 
                                    short_msg => "No problems on system.");
    }

    # Check showfaults
    # Format:
    # Target              | Property               | Value
    #--------------------+------------------------+---------------------------------
    #/SP/faultmgmt/0     | fru                    | /SYS
    #/SP/faultmgmt/0/    | timestamp              | Sep 20 08:08:07
    # faults/0           |                        |
    #/SP/faultmgmt/0/    | sp_detected_fault      | Input power unavailable for PSU
    # faults/0           |                        | at PS1
    
    my @lines = split(/\n/, $otp2);
    my $num_lines = $#lines;
    my $datas = {};
    if ($num_lines > 3) {
        my $severity;
        
        while ($otp2 =~ m/\s+timestamp\s+\|\s+(.*?)\n\s+faults\/([0-9]+)/mg) {
            my $timestamp = $1;
            $timestamp = centreon::plugins::misc::trim($1);
            my $num = $2;
            
            if (defined($self->{option_results}->{memory})) {
                my $old_timestamp = $self->{statefile_cache}->get(name => "fault_$num");
                if (!defined($old_timestamp) || $old_timestamp ne $timestamp) {
                    $severity = 'CRITICAL';
                }
                $datas->{"fault_$num"} = $timestamp;
            } else {
                $severity = 'CRITICAL';
            }
        }
        
        if (defined($severity)) {
            if (defined($self->{option_results}->{memory})) {
                $self->{output}->output_add(severity => 'CRITICAL', 
                                            short_msg => "Some new errors on system (see additional info).");
            } else {
                $self->{output}->output_add(severity => 'CRITICAL', 
                                            short_msg => "Some errors on system (see additional info).");
            }
        }
    }
    
    if (defined($self->{option_results}->{memory})) {
        $self->{statefile_cache}->write(data => $datas);
    }
 
    $self->{output}->display();
    $self->{output}->exit();
}

1;

__END__

=head1 MODE

Check Sun 'T3-x', 'T4-x' and 'T5xxx' Hardware (through ILOM).

=over 8

=item B<--hostname>

Hostname to query.

=item B<--username>

ssh username.

=item B<--password>

ssh password.

=item B<--memory>

Returns new errors (retention file is used by the following option).

=item B<--command-plink>

Plink command (default: plink). Use to set a path.

=item B<--timeout>

Timeout in seconds for the command (Default: 30).

=back

=cut
