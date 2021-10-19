use strict;
use Test;
BEGIN { plan tests => 4; }
use FindBin;
use File::Spec::Functions qw( catfile tmpdir );
use Proc::Background;

=head1 DESCRIPTION

This tests the options 'stdin','stdout','stderr' that assign the file
handles of the child process.  It writes a unique string to a temp file,
then runs a child process that reads stdin and echoes to stdout and stderr,
then it checks that stdout and stderr files have the correct content.

=cut

sub open_or_die {
  open my $fh, $_[0], $_[1] or die "open($_[2]): $!";
  $fh;
}
sub readfile {
  my $fh= open_or_die('<:raw', $_[0]);
  local $/= undef;
  scalar <$fh>;
}
sub writefile {
  my $fh= open_or_die('>:raw', $_[0]);
  print $fh $_[1] or die "print: $!";
  close $fh or die "close: $!";
}

my $tmp_prefix= $FindBin::Script;
$tmp_prefix =~ s/-.*//;

my $io_script_fname= catfile(tmpdir, "$tmp_prefix-io-$$.pl");
writefile($io_script_fname, <<'END');
use strict;
binmode STDIN;
binmode STDOUT;
binmode STDERR;
$/= undef;
my $content= <STDIN>;
print STDOUT $content;
print STDERR $content;
exit 0;
END

my $stdin_fname=  catfile(tmpdir, "$tmp_prefix-stdin-$$.txt" );
my $stdout_fname= catfile(tmpdir, "$tmp_prefix-stdout-$$.txt");
my $stderr_fname= catfile(tmpdir, "$tmp_prefix-stderr-$$.txt");

# Write something to the stdin file.  Then run the script which reads it and echoes to both stdout and stderr.
my ($stdin, $stdout, $stderr);
my $content= "Time = ".time."\r\n";
writefile($stdin_fname, $content);

my $proc= Proc::Background->new({
  stdin => open_or_die('<', $stdin_fname),
  stdout => open_or_die('>', $stdout_fname),
  stderr => open_or_die('>', $stderr_fname),
  command => [ $^X, '-w', $io_script_fname ],
});
ok( !!$proc, 1, 'started child' );  # 1
$proc->wait;
ok( $proc->exit_code, 0, 'exit_code' ); # 2
ok( readfile($stdout_fname), $content, 'stdout content' ); # 3
ok( readfile($stderr_fname), $content, 'stderr content' ); # 4

unlink $stdin_fname;
unlink $stdout_fname;
unlink $stderr_fname;
unlink $io_script_fname;
