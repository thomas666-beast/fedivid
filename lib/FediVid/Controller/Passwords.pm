package FediVid::Controller::Passwords;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use FediVid::Password qw(hash_password check_password);
use FediVid::Signature qw(verify_request verify_digest);

sub update ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT password_hash, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my $body = $c->req->json // {};
    my $new_password = $body->{new_password} // '';
    my $old_password = $body->{old_password};

    unless (length $new_password && length($new_password) >= 8) {
        return $c->render(json => {
            error => 'weak_password',
            detail => 'must be at least 8 characters',
        }, status => 400);
    }

    # Authorize: either a valid signature from the same user's key,
    # or the current password (if one is set).
    my $authed = 0;
    my $reason = 'not authorized';

    if ($user->{password_hash}) {
        if (defined $old_password && check_password($old_password, $user->{password_hash})) {
            $authed = 1;
        } else {
            $reason = 'wrong old password';
        }
    } else {
        my $auth = $c->req->headers->header('Authorization') // '';
        my ($key_id) = $auth =~ /keyId="([^"]+)"/;
        if ($key_id) {
            my $base   = $c->config('scheme') . '://' . $c->config('domain');
            my $expect = "$base/users/$username";
            (my $key_actor = $key_id) =~ s/#.*\z//;
            if ($key_actor eq $expect) {
                my ($sig_ok) = verify_request($c->req, $user->{public_key_pem});
                my ($dig_ok) = verify_digest($c->req);
                if ($sig_ok && $dig_ok) {
                    $authed = 1;
                } else {
                    $reason = 'signature invalid';
                }
            } else {
                $reason = 'keyId mismatch';
            }
        } else {
            $reason = 'no Authorization header and no existing password';
        }
    }

    return $c->render(json => {
        error  => 'unauthorized',
        detail => $reason,
    }, status => 401) unless $authed;

    my $hash = hash_password($new_password);
    $db->query(
        'UPDATE users SET password_hash = ? WHERE username = ?',
        $hash, $username
    );

    $c->render(json => { ok => 1 });
}

1;
