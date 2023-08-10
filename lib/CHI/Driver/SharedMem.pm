package CHI::Driver::SharedMem;

# There is an argument for mapping namespaces into keys and then putting
# different namespaces into different shared memory areas.  I will think about
# that.

use warnings;
use strict;
use Moose;
use IPC::SysV qw(S_IRUSR S_IWUSR IPC_CREAT);
use IPC::SharedMem;
use JSON::MaybeXS;
use Carp;
use Config;
use Fcntl;

extends 'CHI::Driver';

has 'shmkey' => (is => 'ro', isa => 'Int');
has 'shm' => (is => 'ro', builder => '_build_shm', lazy => 1);
has 'size' => (is => 'ro', isa => 'Int', default => 8 * 1024);
has 'lock' => (
	is => 'ro',
	builder => '_build_lock',
);
has '_data_size' => (
	is => 'rw',
	isa => 'Int',
	reader => '_get_data_size',
	writer => '_set_data_size'
);
has '_data' => (
	is => 'rw',
	isa => 'ArrayRef[ArrayRef]',
	reader => '_get_data',
	writer => '_set_data'
);

__PACKAGE__->meta->make_immutable();

=head1 NAME

CHI::Driver::SharedMem - Cache data in shared memory

=head1 VERSION

Version 0.15

=cut

our $VERSION = '0.15';

# FIXME - get the pod documentation right so that the layout of the memory
# area looks correct in the man page

=head1 SYNOPSIS

L<CHI> driver which stores data in shared memory objects for persistence
over processes.
Size is an optional parameter containing the size of the shared memory area,
in bytes.
Shmkey is a mandatory parameter containing the IPC key for the shared memory
area.
See L<IPC::SharedMem> for more information.

    use CHI;
    my $cache = CHI->new(
	driver => 'SharedMem',
	size => 8 * 1024,
	shmkey => 12344321,	# Choose something unique, but the same across
				# all caches so that namespaces will be shared,
				# but we won't step on any other shm areas
    );
    # ...

The shared memory area is stored thus:

	# Number of bytes in the cache [ int ]
	'cache' => {
		'namespace1' => {
			'key1' => 'value1',
			'key2' => 'value2',
			# ...
		},
		'namespace2' => {
			'key1' => 'value3',
			'key3' => 'value2',
			# ...
		}
		# ...
	}

=head1 SUBROUTINES/METHODS

=head2 store

Stores an object in the cache.
The data are serialized into JSON.

=cut

sub store {
	my($self, $key, $value) = @_;

	$self->_lock(type => 'write');
	my $h = $self->_data();
	$h->{$self->namespace()}->{$key} = $value;
	$self->_data($h);
	$self->_unlock();
}

=head2 fetch

Retrieves an object from the cache

=cut

sub fetch {
	my($self, $key) = @_;

	$self->_lock(type => 'read');
	my $rc = $self->_data()->{$self->namespace()}->{$key};
	$self->_unlock();
	return $rc;
}

=head2 remove

Remove an object from the cache

=cut

sub remove {
	my($self, $key) = @_;

	$self->_lock(type => 'write');
	my $h = $self->_data();
	delete $h->{$self->namespace()}->{$key};
	$self->_data($h);
	$self->_unlock();
}

=head2 clear

Removes all data from the current namespace

=cut

sub clear {
	my $self = shift;

	$self->_lock(type => 'write');
	my $h = $self->_data();
	delete $h->{$self->namespace()};
	$self->_data($h);
	$self->_unlock();
}

=head2 get_keys

Gets a list of the keys in the current namespace

=cut

sub get_keys {
	my $self = shift;

	$self->_lock(type => 'read');
	my $h = $self->_data();
	$self->_unlock();
	return(keys(%{$h->{$self->namespace()}}));
}

=head2 get_namespaces

Gets a list of the namespaces in the cache

=cut

sub get_namespaces {
	my $self = shift;

	$self->_lock(type => 'read');
	my $rc = $self->_data();
	$self->_unlock();
	# Needs to be sorted for RT89892
	my @rc = sort keys(%{$rc});
	return @rc;
}

# Internal routines

# The area must be locked by the caller
sub _build_shm {
	my $self = shift;

	my $shm = IPC::SharedMem->new($self->shmkey(), $self->size(), S_IRUSR|S_IWUSR);
	unless($shm) {
		$shm = IPC::SharedMem->new($self->shmkey(), $self->size(), S_IRUSR|S_IWUSR|IPC_CREAT);
		unless($shm) {
			croak 'Couldn\'t create a shared memory area with key ' .
				$self->shmkey() . ": $!";
			return;
		}
		$shm->write(pack('I', 0), 0, $Config{intsize});
	}
	$shm->attach();
	return $shm;
}

sub _build_lock {
	open(my $fd, '<', $0);
	return $fd;
}

sub _lock {
	my ($self, %params) = @_;

	flock($self->lock(), ($params{type} eq 'read') ? Fcntl::LOCK_SH : Fcntl::LOCK_EX);
}

sub _unlock {
	my $self = shift;

	flock($self->lock(), Fcntl::LOCK_UN);
}

# The area must be locked by the caller
sub _data_size {
	my($self, $value) = @_;

	if(defined($value)) {
		$self->shm()->write(pack('I', $value), 0, $Config{intsize});
		return $value;
	}
	unless($self->shm()) {
		return 0;
	}
	my $size = $self->shm()->read(0, $Config{intsize});
	unless(defined($size)) {
		return 0;
	}
	return unpack('I', $size);
}

# The area must be locked by the caller
sub _data {
	my($self, $h) = @_;

	if(defined($h)) {
		my $f = JSON::MaybeXS->new()->ascii()->encode($h);
		my $cur_size = length($f);
		$self->shm()->write($f, $Config{intsize}, $cur_size);
		$self->_data_size($cur_size);
		return $h;
	}
	my $cur_size = $self->_data_size();
	unless($cur_size) {
		return {};
	}
	return JSON::MaybeXS->new()->ascii()->decode($self->shm()->read($Config{intsize}, $cur_size));
}

=head2 BUILD

Constructor - validate arguments

=cut

sub BUILD {
	my $self = shift;

	unless($self->shmkey()) {
		croak 'CHI::Driver::SharedMem - no key given';
	}
}

=head2 DEMOLISH

If there is no data in the shared memory area, and no-one else is using it,
it's safe to remove it and reclaim the memory.

=cut

sub DEMOLISH {
	if(defined($^V) && ($^V ge 'v5.14.0')) {
		return if ${^GLOBAL_PHASE} eq 'DESTRUCT';	# >= 5.14.0 only
	}
	my $self = shift;

	if($self->shmkey()) {
		my $cur_size;
		$self->_lock(type => 'write');
		if(scalar($self->get_namespaces())) {
			$cur_size = $self->_data_size();
		} else {
			$self->_data_size(0);
			$cur_size = 0;
		}
		my $stat = $self->shm()->stat();
		if($cur_size == 0) {
			if(defined($stat) && ($stat->nattch() == 1)) {
				$self->shm()->detach();
				$self->shm()->remove();
			}
		} elsif(defined($stat) && ($stat->nattch() == 1)) {
			# Scan the cache and see if all has expired.
			# If it has, then the cache can be removed if nattch = 1
			my $can_remove = 1;
			foreach my $namespace($self->get_namespaces()) {
				foreach my $key($self->get_keys($namespace)) {
					# May give substr error in CHI
					if($self->is_valid($key)) {
						$can_remove = 0;
						last;
					}
				}
			}
			$self->shm()->detach();
			if($can_remove) {
				$self->shm()->remove();
			}
		} else {
			$self->shm()->detach();
		}
		$self->_unlock();
	}
}

=head1 AUTHOR

Nigel Horne, C<< <njh at bandsman.co.uk> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-chi-driver-sharedmem at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=CHI-Driver-SharedMem>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SEE ALSO

L<CHI>, L<IPC::SharedMem>

=cut

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc CHI::Driver::SharedMemory

You can also look for information at:

=over 4

=item * MetaCPAN

L<https://metacpan.org/dist/CHI-Driver-SharedMem>

=item * RT: CPAN's request tracker

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=CHI-Driver-SharedMemory>

=item * CPAN Testers' Matrix

L<http://matrix.cpantesters.org/?dist=CHI-Driver-SharedMemory>

=item * CPAN Testers Dependencies

L<http://deps.cpantesters.org/?module=CHI::Driver::SharedMemory>

=back

=head1 LICENSE AND COPYRIGHT

Copyright 2010-2023 Nigel Horne.

This program is released under the following licence: GPL2

=cut

1;
