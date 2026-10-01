package FediVid::URLGuard;
use Mojo::Base -strict, -signatures;
use Mojo::URL;
use Socket qw(SOCK_STREAM);

use Exporter 'import';
our @EXPORT_OK = qw(check_url);

my @FORBIDDEN_SUFFIXES = qw(
    .localhost
    .local
    .internal
    .test
    .example
    .invalid
    .onion
);

sub check_url ($url, %opts) {
    my $allow_insecure = $opts{allow_insecure} // 0;
    my $allow_private  = $opts{allow_private}  // 0;

    my $u = eval { Mojo::URL->new($url) };
    return (0, 'unparseable URL') unless $u;

    my $scheme = $u->scheme // '';
    unless ($scheme eq 'https' || ($allow_insecure && $scheme eq 'http')) {
        return (0, "scheme $scheme not allowed");
    }

    my $host = $u->host // '';
    return (0, 'missing host') unless length $host;

    # Test/dev exemption: skip hostname, port, and IP checks
    return (1, undef) if $allow_private;

    if ($host !~ /\A\d+\z/ && $host =~ /[a-z]/i) {
        my $lc = lc $host;
        for my $suffix (@FORBIDDEN_SUFFIXES) {
            return (0, "hostname $host ends in $suffix")
                if $lc =~ /\Q$suffix\E\z/;
        }
        return (0, 'bare "localhost" not allowed') if $lc eq 'localhost';
    }

    my $port = $u->port // ($scheme eq 'https' ? 443 : 80);
    if ($scheme eq 'https') {
        return (0, "port $port not allowed") unless $port == 443;
    } else {
        return (0, "port $port not allowed") unless $port == 80;
    }

    my @ips = _resolve($host);
    return (0, "cannot resolve $host") unless @ips;

    for my $ip (@ips) {
        return (0, "resolved IP $ip is in a private range")
            if _is_private_ip($ip);
    }

    return (1, undef);
}

sub _resolve ($host) {
    my ($err, @res) = Socket::getaddrinfo(
        $host, undef, { socktype => SOCK_STREAM }
    );
    return () if $err;
    my @ips;
    for my $r (@res) {
        my ($nerr, $ip) = Socket::getnameinfo(
            $r->{addr}, Socket::NI_NUMERICHOST()
        );
        push @ips, $ip if !$nerr && $ip;
    }
    return @ips;
}

sub _is_private_ip ($ip) {
    if ($ip =~ /\A(\d+)\.(\d+)\.(\d+)\.(\d+)\z/) {
        my ($a, $b) = ($1, $2);
        return 1 if $a == 0;
        return 1 if $a == 127;
        return 1 if $a == 10;
        return 1 if $a == 172 && $b >= 16 && $b <= 31;
        return 1 if $a == 192 && $b == 168;
        return 1 if $a == 169 && $b == 254;
        return 1 if $a == 224;
        return 1 if $a >= 240;
        return 0;
    }

    my $lc = lc $ip;
    return 1 if $lc eq '::1';
    return 1 if $lc eq '::';
    return 1 if $lc =~ /\Afe[89ab]/;
    return 1 if $lc =~ /\Afc/ || $lc =~ /\Afd/;
    return 0;
}

1;
