package Proc::Background::Unix;

# ABSTRACT: Unix-specific implementation of process create/wait/kill
require 5.004_04;

use strict;
use Exporter;
use Carp;
use POSIX qw(:errno_h :sys_wait_h);
# For un-explained mysterious reasons, Time::HiRes::alarm seem to misbehave on 5.10 and earlier
if ($] >= 5.012) {
	require Time::HiRes;
	Time::HiRes->import('alarm');
}
else {
	*alarm= sub {
		# round up to whole seconds
		CORE::alarm(POSIX::ceil($_[0]));
	};
}

@Proc::Background::Unix::ISA = qw(Exporter);

# Start the background process.  If it is started sucessfully, then record
# the process id in $self->{_os_obj}.
sub _start {
  my ($self, $options)= @_;

  # There are three main scenarios for how-to-exec:
  #   * single-string command, to be handled by shell
  #   * arrayref command, to be handled by execve
  #   * arrayref command with 'exe' (fake argv0)
  # and one that isn't logical:
  #   * single-string command with exe
  # throw an error for that last one rather than trying something awkward
  # like splitting the command string.

  my @argv;
  my $cmd= $self->{_command};
  my $exe= $self->{_exe};

  if (ref $cmd eq 'ARRAY') {
    @argv= @$cmd;
    $exe= Proc::Background::_resolve_path(defined $exe? $exe : $argv[0])
      or return;
    $self->{_exe}= $exe;
  } elsif (defined $exe) {
    croak "Can't combine 'exe' option with single-string 'command', use arrayref 'command' instead.";
  }

  # Fork a child process.
  my $pid;
  {
    if ($pid = fork()) {
      # parent
      $self->{_os_obj} = $pid;
      $self->{_pid}    = $pid;
      last;
    } elsif (defined $pid) {
      # child
      eval {
        chdir($options->{cwd}) or die "chdir($options->{cwd}): $!"
          if defined $options->{cwd};

        open STDIN, '<&', $options->{stdin} or die "Can't redirect STDIN: $!"
          if defined $options->{stdin};
        open STDOUT, '>&', $options->{stdout} or die "Can't redirect STDOUT: $!"
          if defined $options->{stdout};
        open STDERR, '>&', $options->{stderr} or die "Can't redirect STDERR: $!"
          if defined $options->{stderr};

        if (defined $exe) {
          exec { $exe } @argv or die "$0: exec failed: $!\n";
        } else {
          exec $cmd or die "$0: exec failed: $!\n";
        }
      };
      print STDERR $@;
      POSIX::_exit(1);
    } elsif ($! == EAGAIN) {
      sleep 5;
      redo;
    } else {
      return;
    }
  }

  $self;
}

# Wait for the child.
#   (0, exit_value)	: sucessfully waited on.
#   (1, undef)	: process already reaped and exit value lost.
#   (2, undef)	: process still running.
sub _waitpid {
  my ($self, $blocking, $wait_seconds) = @_;

  {
    # Try to wait on the process.
    # Implement the optional timeout with the 'alarm' call.
    my $result= 0;
    if ($blocking && $wait_seconds) {
      local $SIG{ALRM}= sub { die "alarm\n" };
      alarm($wait_seconds);
      eval { $result= waitpid($self->{_os_obj}, 0); };
      alarm(0);
    }
    else {
      $result= waitpid($self->{_os_obj}, $blocking? 0 : WNOHANG);
    }

    # Process finished.  Grab the exit value.
    if ($result == $self->{_os_obj}) {
      return (0, $?);
    }
    # Process already reaped.  We don't know the exist status.
    elsif ($result == -1 and $! == ECHILD) {
      return (1, 0);
    }
    # Process still running.
    elsif ($result == 0) {
      return (2, 0);
    }
    # If we reach here, then waitpid caught a signal, so let's retry it.
    redo;
  }
  return 0;
}

sub _die {
  my $self = shift;
  my @kill_sequence= @_ && ref $_[0] eq 'ARRAY'? @{ $_[0] } : qw( TERM 2 TERM 8 KILL 3 KILL 7 );
  # Try to kill the process with different signals.  Calling alive() will
  # collect the exit status of the program.
  while (@kill_sequence and $self->alive) {
    my $sig= shift @kill_sequence;
    my $delay= shift @kill_sequence;
    kill($sig, $self->{_os_obj});
    last if $self->_reap(1, $delay); # block before sending next signal
  }
}

1;

__END__

=head1 NAME

Proc::Background::Unix - Implementation of process management for Unix systems

=head1 DESCRIPTION

This module does not have a public interface.  Use L<Proc::Background>.

=head1 IMPLEMENTATION

Unix systems start a new process by creating a mirror of the current process
(C<fork>) and then having it alter its own state to prepare for the new
program, and then calling C<exec> to replace the running code with code loaded
from a new file.  However, there is a second common method where the user
wants to specify a command line string as they would type it in their shell.
In this case, the actual program being executed is the shell, and the command
line is given as one element of its argument list.

Perl already supports both methods, such that if you pass one string to C<exec>
containing shell characters, it calls the shell, and if you pass multiple
arguments, it directly invokes C<exec>.

This module mostly just lets Perl's C<exec> do its job, but also checks for
the existence of the executable first, to make errors easier to catch.  This
check is skipped if there is a single-string command line.

Unix lets you run a different executable than what is listed in the first
argument.  (this feature lets one Unix executable behave as multiple
different programs depending on what name it sees in the first argument)
You can use that feature by passing separate options of C<exe> and C<command>
to this module's constructor instead of a simple list.  But, you can't mix
a C<'exe'> option with a shell-interpreted command line string.

=cut
