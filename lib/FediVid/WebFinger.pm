package FediVid::WebFinger;
use Mojo::Base -strict, -signatures;
use Mojo::URL;

use Exporter 'import';
our @EXPORT_OK = qw(resolve_handle);

sub resolve_handle ($ua, $handle) {
    $handle =~ s/\A\@//;
    my ($user, $host) = split /\@/, $handle, 2;
    return undef unless $user && $host;
    return undef if $user =~ m{/} || $host =~ m{/};

    # HTTP for localhost / 127.0.0.1, HTTPS otherwise
    my $scheme = $host =~ m{\A(?:localhost|127\.0\.0\.1)(?::\d+)?\z}
               ? 'http' : 'https';

    my $url = Mojo::URL->new("$scheme://$host/.well-known/webfinger");
    $url->query(resource => "acct:$user\@$host");

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
