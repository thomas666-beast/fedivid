package FediVid::WebFinger;
use Mojo::Base -strict, -signatures;
use Mojo::URL;
use FediVid::URLGuard qw(check_url);

use Exporter 'import';
our @EXPORT_OK = qw(resolve_handle);

sub resolve_handle ($ua, $handle) {
    $handle =~ s/\A\@//;
    my ($user, $host) = split /\@/, $handle, 2;
    return undef unless $user && $host;
    return undef if $user =~ m{/} || $host =~ m{/};

    # Only fall back to HTTP for loopback hosts, and only in dev mode.
    my $allow_insecure = $ENV{FEDIVID_ALLOW_INSECURE_FETCH} // 0;
    my $is_loopback    = $host =~ m{\A(?:localhost|127\.0\.0\.1)(?::\d+)?\z};

    my $scheme = ($is_loopback && $allow_insecure) ? 'http' : 'https';
    my $url    = Mojo::URL->new("$scheme://$host/.well-known/webfinger");
    $url->query(resource => "acct:$user\@$host");

    my ($ok, $err) = check_url(
        $url->to_string,
        allow_insecure => $allow_insecure,
        allow_private  => $allow_insecure,
    );
    return undef unless $ok;

    my $tx = $ua->get($url->to_string, {
        Accept => 'application/jrd+json',
    });

    my $res = $tx->res;
    return undef unless $res && ($res->code // 0) == 200;

    my $jrd = $res->json;
    return undef unless $jrd && ref $jrd->{links} eq 'ARRAY';

    for my $link (@{ $jrd->{links} }) {
        next unless ($link->{rel} // '') eq 'self';
        next unless ($link->{type} // '') =~ m{application/(activity\+json|ld\+json)};
        return $link->{href};
    }

    return undef;
}

1;
