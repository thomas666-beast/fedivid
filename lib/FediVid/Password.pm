package FediVid::Password;
use Mojo::Base -strict, -signatures;
use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);

use Exporter 'import';
our @EXPORT_OK = qw(hash_password check_password);

my $COST = 12;

sub hash_password ($password) {
    my $salt16  = _random_salt16();
    my $encoded = en_base64($salt16);
    my $setting = sprintf('$2a$%02d$%s', $COST, $encoded);
    return bcrypt($password, $setting);
}

sub check_password ($password, $hash) {
    return 0 unless defined $hash && length $hash;

    my $computed = eval { bcrypt($password, $hash) };
    return 0 unless defined $computed;

    return 0 unless length($computed) == length($hash);
    my $diff = 0;
    for my $i (0 .. length($hash) - 1) {
        $diff |= ord(substr($hash, $i, 1)) ^ ord(substr($computed, $i, 1));
    }
    return $diff == 0;
}

sub _random_salt16 {
    my $raw = '';
    open my $fh, '<', '/dev/urandom' or die "open /dev/urandom: $!";
    read $fh, $raw, 16;
    close $fh;
    return $raw;
}

1;
