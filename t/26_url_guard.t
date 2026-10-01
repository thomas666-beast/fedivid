use Mojo::Base -strict, -signatures;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid::URLGuard qw(check_url);

# --- Private IPv4 literals (always rejected regardless of allow_private) ---
for my $bad (
    'http://127.0.0.1/foo',
    'http://10.0.0.1/foo',
    'http://172.16.0.1/foo',
    'http://192.168.1.1/foo',
    'http://169.254.169.254/latest/meta-data/',
) {
    my ($ok, $err) = check_url($bad, allow_insecure => 1);
    ok !$ok, "rejected: $bad" or diag "error: $err";
}

# --- Forbidden hostnames ---
for my $bad (
    'http://localhost/foo',
    'http://foo.localhost/foo',
    'http://service.internal/foo',
    'http://foo.local/foo',
) {
    my ($ok, $err) = check_url($bad, allow_insecure => 1);
    ok !$ok, "rejected: $bad" or diag "error: $err";
}

# --- Scheme ---
{
    my ($ok, $err) = check_url('http://example.com/foo');
    ok !$ok, 'http rejected when insecure not allowed';
}
{
    my ($ok, $err) = check_url('ftp://example.com/foo');
    ok !$ok, 'unsupported scheme rejected';
}

# --- Port ---
{
    my ($ok, $err) = check_url('https://example.com:8443/foo');
    ok !$ok, 'non-standard https port rejected';
}

# --- Accepted (real DNS for example.com) ---
{
    my ($ok, $err) = check_url('https://example.com/users/bob');
    ok $ok, 'https to public host accepted' or diag "error: $err";
}

# --- allow_private bypasses IP resolution ---
{
    my ($ok, $err) = check_url(
        'http://127.0.0.1/users/bob',
        allow_insecure => 1,
        allow_private  => 1,
    );
    ok $ok, 'allow_private permits loopback' or diag "error: $err";
}

done_testing();
