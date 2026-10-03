package FediVid::Auth;
use Mojo::Base -strict, -signatures;
use FediVid::Signature qw(verify_request verify_digest);

use Exporter 'import';
our @EXPORT_OK = qw(authenticate_as current_user current_user_required);

# Returns ($ok, $error_detail).
#   $user is a hashref with at least public_key_pem (usually a SELECT * from users)
#   $username is the user we're authenticating as
#
# Auth passes if either:
#   - the session cookie identifies the same user, OR
#   - the request is signed with the user's key (HTTP Signature)
sub authenticate_as ($c, $user, $username = undef) {
    # Some controllers know the username from a URL param; others pass it
    # explicitly. Fall back to the param when not given.
    $username //= $c->param('username');

    my $session_user = current_user($c);
    return (1, undef) if $session_user && $session_user eq $username;

    return (0, 'user has no public key') unless $user->{public_key_pem};

    my $auth = $c->req->headers->header('Authorization') // '';
    return (0, 'missing Authorization header') unless $auth;

    my ($key_id) = $auth =~ /keyId="([^"]+)"/;
    return (0, 'missing keyId') unless $key_id;

    my $base   = $c->config('base_url');
    my $expect = "$base/users/$username";

    (my $key_actor = $key_id) =~ s/#.*\z//;
    return (0, 'keyId does not match user') unless $key_actor eq $expect;

    my ($sig_ok, $sig_err) = verify_request($c->req, $user->{public_key_pem});
    return (0, "signature: $sig_err") unless $sig_ok;

    my ($digest_ok, $digest_err) = verify_digest($c->req);
    return (0, "digest: $digest_err") unless $digest_ok;

    return (1, undef);
}

# Returns the username of the session user, or undef if not logged in.
sub current_user ($c) {
    require FediVid::Controller::Sessions;
    return eval { FediVid::Controller::Sessions::_current_user($c) };
}

# Returns the username of the session user, or dies if not logged in.
# (Not used yet, but a natural helper for future controllers.)
sub current_user_required ($c) {
    my $u = current_user($c);
    die "not authenticated\n" unless $u;
    return $u;
}

1;
