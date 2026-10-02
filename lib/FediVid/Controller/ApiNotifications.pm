package FediVid::Controller::ApiNotifications;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use FediVid::Signature qw(verify_request verify_digest);

sub index ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user, $username);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    my $rows = $db->query(
        'SELECT id, type, actor, object_id, object_url, video_id, created_at, seen_at
           FROM notifications
          WHERE username = ?
          ORDER BY created_at DESC
          LIMIT 100',
        $username
    )->hashes;

    my $unseen = $db->query(
        'SELECT COUNT(*) AS n FROM notifications
          WHERE username = ? AND seen_at IS NULL',
        $username
    )->hash->{n};

    $c->render(json => {
        totalItems => scalar @$rows,
        unseen     => $unseen + 0,
        items      => [ map {
            {
                id         => $_->{id} + 0,
                type       => $_->{type},
                actor      => $_->{actor},
                object_id  => $_->{object_id},
                object_url => $_->{object_url},
                created_at => $_->{created_at},
                seen       => $_->{seen_at} ? 1 : 0,
                video_id   => $_->{video_id} ? $_->{video_id} + 0 : undef,
            }
        } @$rows ],
    });
}

sub seen ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user, $username);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    $db->query(
        'UPDATE notifications SET seen_at = NOW()
          WHERE username = ? AND seen_at IS NULL',
        $username
    );

    $c->render(json => { ok => 1 });
}

sub _authenticate_as ($c, $user, $username) {
    my $session_user = eval {
        require FediVid::Controller::Sessions;
        FediVid::Controller::Sessions::_current_user($c);
    };
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

1;
