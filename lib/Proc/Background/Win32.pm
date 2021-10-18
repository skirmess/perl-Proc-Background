package Proc::Background::Win32;

# ABSTRACT: Windows-specific implementation of process create/wait/kill
require 5.004_04;

use strict;
use Exporter;
use Carp;
use Win32::Process qw( NORMAL_PRIORITY_CLASS INFINITE );
use Win32::ShellQuote ();

@Proc::Background::Win32::ISA = qw(Exporter);

sub _start {
  my ($self, $options)= @_;
  my ($exe, $cmd, $cmdline)= ( $self->{_exe}, $self->{_command}, undef );

  # If 'command' is a single string, treat it as system() would and assume
  # it should be split into arguments.  The first argument is then the
  # application executable, if not already specified as an option.
  if (ref $cmd ne 'ARRAY') {
    $cmdline= $cmd;
    ($exe) = Win32::ShellQuote::unquote_native($cmdline)
      unless defined $exe;
  }
  # system() would treat a list of arguments as an un-quoted ARGV
  # for the program, so concatenate them into a command line appropriate
  # for Win32 CommandLineToArgvW to decode back to what we started with.
  # Preserve the first un-quoted argument for use as lpApplicationName.
  else {
    $exe = $cmd->[0] unless defined $exe;
    $cmdline= Win32::ShellQuote::quote_native(@$cmd);
  }

  # Find the absolute path to the program.  If it cannot be found,
  # then return.  To work around a problem where
  # Win32::Process::Create cannot start a process when the full
  # pathname has a space in it, convert the full pathname to the
  # Windows short 8.3 format which contains no spaces.
  $exe = Proc::Background::_resolve_path($exe) or return;
  $exe = Win32::GetShortPathName($exe);

  # Perl 5.004_04 cannot run Win32::Process::Create on a nonexistant
  # hash key.
  my $os_obj = 0;

  # Create the process.
  Win32::Process::Create($os_obj, $exe, $cmdline, 0, NORMAL_PRIORITY_CLASS, '.')
    or return;

  $self->{_pid}    = $os_obj->GetProcessID;
  $self->{_os_obj} = $os_obj;
}

# Reap the child.
#   (0, exit_value)	: sucessfully waited on.
#   (1, undef)	: process already reaped and exit value lost.
#   (2, undef)	: process still running.
sub _waitpid {
  my ($self, $blocking, $wait_seconds) = @_;

  # Try to wait on the process.
  my $result = $self->{_os_obj}->Wait($wait_seconds? int($wait_seconds * 1000) : $blocking ? INFINITE : 0);
  # Process finished.  Grab the exit value.
  if ($result == 1) {
    my $exit_code;
    $self->{_os_obj}->GetExitCode($exit_code);
    if ($exit_code == 256 && $self->{_called_terminateprocess}) {
      return (0, 9); # simulate SIGKILL exit status
    } else {
      return (0, $exit_code<<8);
    }
  }
  # Process still running.
  elsif ($result == 0) {
    return (2, 0);
  }
  # If we reach here, then something odd happened.
  return (0, 1<<8);
}

sub _die {
  my $self = shift;
  my @kill_sequence= @_ && ref $_[0] eq 'ARRAY'? @{ $_[0] } : qw( TERM 2 TERM 8 KILL 3 KILL 7 );

  # Try the kill the process several times.
  # _reap will collect the exit status of the program.
  while (@kill_sequence and $self->alive) {
    my $sig= shift @kill_sequence;
    my $delay= shift @kill_sequence;
    $sig eq 'KILL'? $self->_send_sigkill : $self->_send_sigterm;
    last if $self->_reap(1, $delay); # block before sending next signal
  }
}

# Use taskkill.exe as a sort of graceful SIGTERM substitute.
sub _send_sigterm {
  my $self = shift;
  # TODO: This doesn't work reliably.  Disabled for now, and continue to be heavy-handed
  # using TerminateProcess.  The right solution would either be to do more elaborate setup
  # to make sure the correct taskkill.exe is used (and available), or to dig much deeper
  # into Win32 API to enumerate windows or threads and send WM_QUIT, or whatever other APIs
  # processes might be watching on Windows.  That should probably be its own module.
  # my $pid= $self->{_pid};
  # my $out= `taskkill.exe /PID $pid`;
  # If can't run taskkill, fall back to TerminateProcess
  # $? == 0 or
  $self->_send_sigkill;
}

# Win32 equivalent of SIGKILL is TerminateProcess()
sub _send_sigkill {
  my $self = shift;
  $self->{_os_obj}->Kill(256);  # call TerminateProcess, essentially SIGKILL
  $self->{_called_terminateprocess} = 1;
}

1;

__END__

=head1 NAME

Proc::Background::Win32 - Implementation of process management for Win32 systems

=head1 DESCRIPTION

This module does not have a public interface.  Use L<Proc::Background>.

=head1 IMPLEMENTATION

When Perl is built as a native Win32 application, the C<fork> and C<exec> are
a broken approximation of their Unix counterparts.  Calling C<fork> creates a
I<thread> instead of a process, and there is no way to exit the thread without
running Perl cleanup code, which could damage the parent in unpredictable
ways, like closing file handles.  Calling C<POSIX::_exit> will kill both
parent and child (the whole process), and even calling C<exec> in the child
still runs global destruction.  File handles are shared between parent and
child, so any file handle redirection you perform in the forked child will
affect the parent and vice versa.

In short, B<never> call C<fork> or C<exec> on native Win32 Perl.

This module implements background processes using C<Win32::Process>, which
uses the Windows API's concepts of C<CreateProcess>, C<TerminateProces>,
C<WaitForSingleObject>, C<GetExitCode>, and so on.

Windows CreateProcess expects an executable name and a command line; breaking
the command line into an argument list is left to each individual application,
most of which use the library function C<CommandLineToArgvW>.  This module
C<Win32::ShellQuote> to parse and format Windows command lines.

If you supply a single-string command line, and don't specify the executable
with the C<'exe'> option, it splits the command line and uses the first
argument.  Then it looks for that argument in the C<PATH>, searching again
with a suffix of C<".exe"> if the original wasn't found.

If you supply a command of multiple arguments, they are combined into a command
line using C<Win32::ShellQuote>.  The first argument is used as the executable
(unless you specified the C<'exe'> option), and gets the same path lookup.

=cut
