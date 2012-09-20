#!/usr/bin/perl -w

BEGIN {
  push @INC, "/usr/lib/obs/server";
  push @INC, "/usr/lib/obs/server/build";
}

use XML::Structured ':bytes';

use Build;
use BSConfig;
use BSUtil;
use BSXML;
use BSSolv;
use Meta;


my $reporoot  = "$BSConfig::bsdir/build";
my $eventroot = "$BSConfig::bsdir/events";
my $projectsdir = "$BSConfig::bsdir/projects";
my $rundir = $BSConfig::rundir || "$BSConfig::bsdir/projects";

print "running as user: " . getpwuid($<) . "\n";
print "Download on Demand enabled: " . $BSConfig::enable_download_on_demand . "\n";
print "repositories: " . $reporoot . "\n";
print "eventroot: " . $eventroot . "\n";
print "projectsdir: " . $projectsdir . "\n";

sub write_event {
  my ($project, $repo, $arch, $event, $package) = @_;
  my $evname = "${event}::$project";
  $evname .= "::$package" if defined $package;
  $evname .= "::$repo" if defined $repo;
  my $ev = { 'type' => $event };
  $ev->{'project'} = $project if defined $project;
  $ev->{'package'} = $package if defined $package;
  $ev->{'repository'} = $repo if defined $repo;
  writexml("$eventroot/$arch/.$evname$$", "$eventroot/$arch/$evname", $ev, $BSXML::event);
  local *F;
  if (sysopen(F, "$eventroot/$arch/.ping", POSIX::O_WRONLY|POSIX::O_NONBLOCK)) {
    syswrite(F, 'x');
    close(F);
  }
}

sub writesolv {
  my ($fn, $fnf, $repo) = @_;
  if (defined($fnf) && $BSUtil::fdatasync_before_rename) {
    local *F;
    open(F, '>', $fn) || die("$fn: $!\n");
    $repo->tofile_fd(fileno(F));
    BSUtil::do_fdatasync(fileno(F));
    close(F) || die("$fn close: $!\n");
  } else {
    $repo->tofile($fn);
  }
  return unless defined $fnf;
  $! = 0;
  rename($fn, $fnf) || die("rename $fn $fnf: $!\n");
}

sub open_solvfile {
  my ($proj, $pool, $dir) = @_;

  if (-s "$dir.solv") {
    eval {$cache = $pool->repofromfile($proj, "$dir.solv");};
	warn($@) if $@;
	return $cache
  } else {
    print "No solv file found!\n";
	return undef;
  }
}

sub check_dod {
  my ($proj, $r, $d) = @_;
  my $pool = BSSolv::pool->new();
  my %solvpackages = ();
  my %mcache = ();


  print "== Checking DoD for $proj->{name} $r->{name} $d->{arch} ==\n";
  print "Metafile: ". $d->{metafile} . "\n";
  print "Baseurl: ". $d->{baseurl} . "\n";
  print "Download type: ". $d->{mtype} . "\n";

  my $dir = "$reporoot/$proj->{name}/$r->{name}/$d->{arch}/:full";
  print "Meta file: $dir/$d->{'metafile'} \n";

  eval {$mcache = Meta::parse("$dir/$d->{'metafile'}", $d->{'mtype'}, { 'arch' => [ $d->{arch} ] })};
  if ($@) {
    print "    download on demand: cannot read metadata: $@\n";
    return undef;
  } elsif (!$mcache) {
    print "    download on demand: cannot read metadata: unknown mtype attribute\n";
    return undef;
  }
  print  "Package metadata contains " . scalar(keys $mcache). " packages \n";

  $cache = open_solvfile ($proj, $pool, $dir);
  if (!defined $cache) {
    my $i = 0;
	print "Asking the scheduler to recheck\n";
	write_event($proj->{name}, $r->{name}, $d->{arch}, 'recheck');

    if (!(-e "$rundir/bs_sched.$d->{arch}.lock") 
 		|| BSUtil::lockcheck('>>', "$rundir/bs_sched.$d->{arch}.lock")) {
	  die "Scheduler for $d->{arch} not running, please start and rerun $0\n";
    }
    while (!defined $cache && $i < 12) {
	  print "Waiting 5 seconds for the solv file to appear...\n";
	  sleep 5;
      $cache = open_solvfile ($proj, $pool, $dir);
	  $i++;
	}
  }

  if (!defined $cache) {
    print "Still no solv file, trying to create one?\n";
    writesolv ("$dir.solv.tmptest", "$dir.test.solv", $pool->repofromdata($r->{name}, $mcache));
    $cache = open_solvfile ($proj, $pool, "$dir.test");
    die "Couldn't read back our own solv file!?" if ! defined $cache;
    print "Read back from our temporary solv file, how odd\n";
    print "REPOSITORY SETUP STILL BROKEN\n";
    unlink "$dir.test.solv";
  }

  %solvpackages = $cache->pkgnames();
  print  "solve data contains " . scalar(keys %solvpackages) . " packages \n";

  print "Checking metadata vs. solv...\n";
  for $p (keys $mcache) {
    print "Missing $p\n" if not $solvpackages{$p};
  }

  print "Checking solv vs. metadata...\n";
  for $p (keys %solvpackages) {
    print "Missing $p\n" if not $mcache->{$p};
  }
}

my $project = shift @ARGV;
my $file = "$projectsdir/$project.xml";

my $meta = readxml("$file", $BSXML::proj, 0);

die "Failed to parse xml at $file" unless defined($meta);

print "Project name: " . $meta->{name} . "\n";

foreach my $r (@{$meta->{'repository'}}) {
  foreach my $d (@{$meta->{'download'}}) {
  	check_dod ($meta, $r, $d)
  }
}

