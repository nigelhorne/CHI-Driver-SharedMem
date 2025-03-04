#!perl -w

use strict;
use warnings;

use Test::Most;
use Test::Warn;
use CHI;
use IPC::SysV qw(S_IRUSR S_IWUSR);
use IPC::SharedMem;

BEGIN {
	use_ok('CHI::Driver::SharedMem') || print 'Bail out!';
}

NEW: {
	my $shm;
	my $SIGSYS_count = 0;
	my $shm_key = 1221;

	eval {
		local $SIG{SYS} = sub { $SIGSYS_count++ };
		if($shm = IPC::SharedMem->new($shm_key, 8 * 1024, S_IRUSR|S_IWUSR)) {
			$shm->remove();
			$shm = IPC::SharedMem->new($shm_key, 8 * 1024, S_IRUSR|S_IWUSR);
		}
	};
	if($@ || $SIGSYS_count) {
		if($^O eq 'cygwin') {
			BAIL_OUT("It may be that the cygserver service isn't running.");
		}
	} else {
		ok(!defined($shm), 'Shared memory area does not exist before the test');
		{
			my $cache = CHI->new(driver => 'SharedMem', shm_key => $shm_key);
			ok(defined($cache));

			# Calling get_namespaces() will force the area to be created
			my @a = $cache->get_namespaces();
			ok((scalar(@a) == 0), 'The cache is empty');

			$shm = IPC::SharedMem->new($shm_key, 8 * 1024, S_IRUSR|S_IWUSR);
			ok(defined($shm), 'Shared memory exists during the test');

			# diag('Ignore no key given message');
			# warning_like
				# { $cache = CHI->new(driver => 'SharedMem') }
				# { carped => qr/CHI::Driver::SharedMem - no shm_key given/ };

			eval {
				$cache = CHI->new(driver => 'SharedMem');
			};
			if($@) {
				ok($@ =~ /CHI::Driver::SharedMem: no shm_key given/);
			} else {
				ok(0, 'Allowed shmkey to be undefined');
			}
		}

		$shm = IPC::SharedMem->new($shm_key, 8 * 1024, S_IRUSR|S_IWUSR);
		ok(!defined($shm), 'Shared memory area does not exist after the test');
	}
	done_testing();
}
