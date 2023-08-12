#!/usr/bin/perl -w

use strict;
use warnings;
use IPC::SysV qw(S_IRUSR S_IWUSR);
use IPC::SharedMem;
use Test::Most tests => 4;
use Test::NoWarnings;

use_ok('CHI');

my $shmkey = 44334433;
my $size = 40;

my $shm;
if(defined($shm = IPC::SharedMem->new($shmkey, $size, S_IRUSR|S_IWUSR))) {
	$shm->remove();
}

{
	my $s = CHI->new(driver => 'SharedMem', size => $size, shmkey => $shmkey, max_size => $size);

	$s->on_set_error('warn');

	$s->set('xyzzy', 'x' x 10, '5 mins');
	ok($s->get('xyzzy') eq 'x' x 10);

	$s->set('xyzzy', 'x' x 80, '5 mins');
	ok(!defined($s->get('xyzzy')));
}

# Remove the shared memory area we've just created.
if(defined($shm = IPC::SharedMem->new($shmkey, $size, S_IRUSR|S_IWUSR))) {
	$shm->remove();
}
