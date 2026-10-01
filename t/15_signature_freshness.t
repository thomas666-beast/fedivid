use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid::Signature qw(sign_request verify_request);
use Mojo::UserAgent;
use Mojo::Date;
use Mojo::Util qw(b64_encode);
use Digest::SHA qw(sha256);
use MIME::Base64 qw(decode_base64);
use Crypt::OpenSSL::RSA;

my $rsa         = Crypt::OpenSSL::RSA->generate_key(2048);
my $private_pem = $rsa->get_private_key_string();
my $public_pem  = $rsa->get_public_key_x509_string();
my $key_id      = 'https://example.test/users/alice#main-key';

my $ua = Mojo::UserAgent->new;

# Helper: build a request signed over an arbitrary Date header.
# We can't use sign_request() because it always uses time().
sub signed_with_date ($seconds_ago) {
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body('{"type":"Follow"}');

    my $date = Mojo::Date->new(time - $seconds_ago)->to_string;
    $tx->req->headers->header('Date' => $date);
    $tx->req->headers->header('Host' => $tx->req->url->host_port);

    my $body   = $tx->req->body;
    my $digest = 'SHA-256=' . b64_encode(sha256($body), '');
    $tx->req->headers->header('Digest' => $digest);

    my $target = $tx->req->url->path->to_string;
    my $query  = $tx->req->url->query->to_string;
    $target .= "?$query" if length $query;

    my $signing_string = join("\n",
        "(request-target): post $target",
        "host: " . $tx->req->headers->header('Host'),
        "date: $date",
        "digest: $digest",
    );

    my $sig = b64_encode($rsa->sign($signing_string), '');
    $tx->req->headers->header('Authorization' =>
        qq{Signature keyId="$key_id",algorithm="rsa-sha256",}
      . qq{headers="(request-target) host date digest",signature="$sig"}
    );

    return $tx;
}

# --- Fresh request (now) still verifies ---
{
    my $tx = signed_with_date(0);
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok $ok, 'fresh signature verifies' or diag "error: $err";
}

# --- Request signed 5 minutes ago: still acceptable ---
{
    my $tx = signed_with_date(5 * 60);
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok $ok, '5-minute-old signature still accepted' or diag "error: $err";
}

# --- Request signed 1 hour ago: rejected ---
{
    my $tx = signed_with_date(3600);
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok !$ok, '1-hour-old signature rejected';
    like $err, qr/Date/, 'error mentions Date';
    like $err, qr/skew|stale|old/i, 'error mentions staleness';
}

# --- Request signed 1 day ago: rejected ---
{
    my $tx = signed_with_date(24 * 3600);
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok !$ok, '1-day-old signature rejected';
}

# --- Date header in the future by 1 hour: rejected ---
{
    my $tx = signed_with_date(-3600);   # negative = future
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok !$ok, 'future-dated signature rejected';
}

# --- Missing Date header: rejected ---
{
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body('{"type":"Follow"}');
    sign_request($tx->req, $key_id, $private_pem);
    $tx->req->headers->remove('Date');

    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok !$ok, 'missing Date header rejected';
}

# --- Unparseable Date header: rejected ---
{
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->headers->content_type('application/activity+json');
    $tx->req->body('{"type":"Follow"}');

    my $bad_date = 'not a real date';
    $tx->req->headers->header('Date' => $bad_date);
    $tx->req->headers->header('Host' => $tx->req->url->host_port);

    my $digest = 'SHA-256=' . b64_encode(sha256($tx->req->body), '');
    $tx->req->headers->header('Digest' => $digest);

    my $target = $tx->req->url->path->to_string;
    my $signing_string = join("\n",
        "(request-target): post $target",
        "host: " . $tx->req->headers->header('Host'),
        "date: $bad_date",
        "digest: $digest",
    );
    my $sig = b64_encode($rsa->sign($signing_string), '');
    $tx->req->headers->header('Authorization' =>
        qq{Signature keyId="$key_id",algorithm="rsa-sha256",}
      . qq{headers="(request-target) host date digest",signature="$sig"}
    );

    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok !$ok, 'unparseable Date rejected';
}

done_testing();
