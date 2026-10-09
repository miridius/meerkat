#!/usr/bin/perl
# Runs a command once it holds one of the gate's two slots, so at most two
# gates in all worktrees of a repo run their heavy checks at once.
#
#   perl scripts/gate-lock.pl <lock dir> <command> [<arg>...]
#
# Each slot is an flock(2) on a file in <lock dir>. The kernel releases it
# when this process exits, however it exits, so a crashed gate never leaves
# a stale lock. The command runs as a child that does not inherit the lock,
# so a process it leaves behind does not hold a slot either. The command
# gets MEERKAT_GATE_LOCK=<lock dir>, which tells a script that re-runs
# itself under this lock that it already holds a slot.
#
# Waiting gates queue on a third lock and take slots in turn: only the one at
# the head of the queue tries the slots, twice a second. Each prints that it
# is waiting. Exits as the command does, dying by the signal that killed it.
use strict;
use warnings;
use Fcntl qw(:flock);
use Time::HiRes ();

my $slots = 2;

my ($dir, @cmd) = @ARGV;
die "usage: gate-lock.pl <lock dir> <command> [<arg>...]\n" unless defined $dir && @cmd;
mkdir $dir;
-d $dir or die "gate-lock: cannot create $dir: $!\n";

sub open_lock {
  my ($name) = @_;
  open(my $fh, '>>', "$dir/$name") or die "gate-lock: cannot open $dir/$name: $!\n";
  return $fh;
}

sub take_slot {
  for my $i (1 .. $slots) {
    my $fh = open_lock("slot$i");
    return $fh if flock($fh, LOCK_EX | LOCK_NB);
    close $fh;
  }
  return;
}

my $start = Time::HiRes::time();
my $waited = 0;
sub waiting {
  return if $waited++;
  print STDERR "gate-lock: $slots gates are already running checks in this repo; waiting for one to finish.\n";
}

# Newcomers queue too, so none takes a slot ahead of a gate already waiting.
my $queue = open_lock('queue');
unless (flock($queue, LOCK_EX | LOCK_NB)) {
  waiting();
  flock($queue, LOCK_EX) or die "gate-lock: cannot lock $dir/queue: $!\n";
}
my $slot;
until ($slot = take_slot()) {
  waiting();
  Time::HiRes::sleep(0.5);
}
close $queue;
printf STDERR "gate-lock: got a slot after %.0fs.\n", Time::HiRes::time() - $start if $waited;

$ENV{MEERKAT_GATE_LOCK} = $dir;
my $pid = fork();
die "gate-lock: fork: $!\n" unless defined $pid;
if ($pid == 0) {
  # Perl opens files close-on-exec, so the command does not inherit $slot.
  exec { $cmd[0] } @cmd or die "gate-lock: exec $cmd[0]: $!\n";
}

# An interrupt from the terminal reaches the command's process group too, so
# this process outlives it and reports how it ended. A signal sent to this
# process alone is passed on.
$SIG{INT} = $SIG{QUIT} = 'IGNORE';
$SIG{TERM} = $SIG{HUP} = sub { kill $_[0], $pid };

while (waitpid($pid, 0) == -1) {
  die "gate-lock: waitpid: $!\n" unless $!{EINTR};
}
my $status = $?;
close $slot;

if (my $signal = $status & 127) {
  $SIG{$_} = 'DEFAULT' for qw(INT QUIT TERM HUP);
  kill $signal, $$;
  exit 128 + $signal;
}
exit $status >> 8;
