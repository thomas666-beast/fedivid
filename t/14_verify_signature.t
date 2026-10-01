use Mojo::Base -strict;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid::Signature qw(sign_request verify_request);
use Mojo::UserAgent;
use Crypt::OpenSSL::RSA;

my $rsa = Crypt::OpenSSL::RSA->generate_key(2048);
my $private_pem = $rsa->get_private_key_string();
my $public_pem  = $rsa->get_public_key_x509_string();
my $key_id      = 'https://example.test/users/alice#main-key';

my $ua = Mojo::UserAgent->new;

# --- Happy path: sign then verify ---
{
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->body('{"type":"Follow"}');
    $tx->req->headers->content_type('application/activity+json');
    sign_request($tx->req, $key_id, $private_pem);

    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok $ok, 'valid signature verifies' or diag "error: $err";
}

# --- Tampered Digest header ---
{
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->body('{"type":"Follow"}');
    sign_request($tx->req, $key_id, $private_pem);

    $tx->req->headers->header('Digest' =>
        'SHA-256=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=');
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok !$ok, 'tampered Digest header fails verification';
    like $err, qr/does not verify/, 'error mentions verification';
}

# --- Wrong public key ---
{
    my $other = Crypt::OpenSSL::RSA->generate_key(2048);
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->body('{"type":"Follow"}');
    sign_request($tx->req, $key_id, $private_pem);

    my ($ok, $err) = verify_request(
        $tx->req, $other->get_public_key_x509_string()
    );
    ok !$ok, 'wrong public key fails verification';
}

# --- Missing Authorization ---
{
    my $tx = $ua->build_tx(GET => 'https://remote.test/users/bob');
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok !$ok, 'missing Authorization fails';
    like $err, qr/missing Authorization/, 'correct error message';
}

# --- Not a Signature header ---
{
    my $tx = $ua->build_tx(GET => 'https://remote.test/users/bob');
    $tx->req->headers->header('Authorization' => 'Bearer abc123');
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok !$ok, 'non-Signature Authorization fails';
    like $err, qr/not a Signature/, 'correct error message';
}

# --- Missing signed header ---
{
    my $tx = $ua->build_tx(GET => 'https://remote.test/users/bob');
    $tx->req->headers->header('Host' => 'remote.test');
    $tx->req->headers->header('Date' => 'Thu, 01 Jan 2026 00:00:00 GMT');
    $tx->req->headers->header('Authorization' =>
        'Signature keyId="k",algorithm="rsa-sha256",'
      . 'headers="(request-target) host date x-missing",signature="AAAA"'
    );
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok !$ok, 'missing signed header fails';
    like $err, qr/x-missing/, 'error mentions the missing header';
}

# --- GET without body ---
{
    my $tx = $ua->build_tx(GET => 'https://remote.test/users/bob');
    sign_request($tx->req, $key_id, $private_pem);
    my ($ok, $err) = verify_request($tx->req, $public_pem);
    ok $ok, 'GET signature verifies' or diag "error: $err";
}

# --- verify_digest ---
use FediVid::Signature qw(verify_digest);

# Matching digest
{
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->body('{"type":"Follow"}');
    sign_request($tx->req, $key_id, $private_pem);
    my ($ok, $err) = verify_digest($tx->req);
    ok $ok, 'correct digest verifies' or diag "error: $err";
}

# Swapped body, original digest — should fail
{
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->body('{"type":"Follow"}');
    sign_request($tx->req, $key_id, $private_pem);
    $tx->req->body('{"type":"Block"}');
    my ($ok, $err) = verify_digest($tx->req);
    ok !$ok, 'swapped body with old digest fails';
    like $err, qr/does not match/, 'error mentions mismatch';
}

# Body present, no Digest header
{
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->body('{"type":"Follow"}');
    my ($ok, $err) = verify_digest($tx->req);
    ok !$ok, 'body without Digest header fails';
    like $err, qr/no Digest/, 'error mentions missing Digest';
}

# No body, no Digest header — OK
{
    my $tx = $ua->build_tx(GET => 'https://remote.test/users/bob');
    my ($ok, $err) = verify_digest($tx->req);
    ok $ok, 'GET with no body passes digest check';
}

# Unsupported algorithm
{
    my $tx = $ua->build_tx(POST => 'https://remote.test/users/bob/inbox');
    $tx->req->body('{"type":"Follow"}');
    $tx->req->headers->header('Digest' => 'SHA-512=whatever');
    my ($ok, $err) = verify_digest($tx->req);
    ok !$ok, 'unsupported digest algorithm fails';
    like $err, qr/unsupported/, 'error mentions unsupported algorithm';
}

done_testing();
