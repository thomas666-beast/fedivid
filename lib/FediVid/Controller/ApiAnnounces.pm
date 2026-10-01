package FediVid::Controller::ApiAnnounces;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json);
use FediVid::Signature qw(verify_request verify_digest);

sub create ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    my $body    = $c->req->json // {};
    my $object  = $body->{object} // '';
    return $c->render(json => { error => 'missing_object' }, status => 400)
        unless length $object;

    my $base = $c->config('base_url');

    my $existing = $db->query(
        'SELECT id FROM announces
          WHERE username = ? AND object_url = ? AND is_remote = FALSE',
        $username, $object
    )->hash;
    return $c->render(json => {
        error  => 'already_announced',
        id     => $existing->{id} + 0,
    }, status => 409) if $existing;

    my $activity_id = "$base/users/$username#announces/" . time . '-' . int(rand(1_000_000));

    my $row = $db->query(
        'INSERT INTO announces
             (username, actor, object_url, activity_id, is_remote)
              VALUES (?, ?, ?, ?, FALSE)
         RETURNING id, created_at',
        $username, "$base/users/$username", $object, $activity_id
    )->hash;

    my $activity = {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => $activity_id,
        type       => 'Announce',
        actor      => "$base/users/$username",
        object     => $object,
        to         => ['https://www.w3.org/ns/activitystreams#Public'],
        published  => _now_iso(),
    };

    my $followers = $db->query(
        'SELECT remote_inbox FROM followers
          WHERE local_user = ? AND accepted = TRUE AND remote_inbox IS NOT NULL',
        $username
    )->arrays;

    require FediVid::DeliveryQueue;
    for my $f (@$followers) {
        FediVid::DeliveryQueue::enqueue($db, $username, $f->[0], $activity);
    }

    $c->render(
        status => 201,
        json   => {
            id         => $row->{id} + 0,
            type       => 'Announce',
            actor      => "$base/users/$username",
            object     => $object,
            created_at => $row->{created_at},
        },
    );
}

sub delete ($c) {
    my $username  = $c->param('username');
    my $announce  = $c->param('id');
    my $db        = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = _authenticate_as($c, $user);
    return $c->render(json => {
        error  => 'unauthorized',
        detail => $auth_err,
    }, status => 401) unless $authed;

    my $row = $db->query(
        'SELECT id, activity_id, object_url FROM announces
          WHERE id = ? AND username = ? AND is_remote = FALSE',
        $announce, $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $row;

    $db->query('DELETE FROM announces WHERE id = ?', $row->{id});

    my $base = $c->config('base_url');

    my $undo = {
        '@context' => 'https://www.w3.org/ns/activitystreams',
        id         => "$base/users/$username#undos/" . time . '-' . int(rand(1_000_000)),
        type       => 'Undo',
        actor      => "$base/users/$username",
        object     => {
            id     => $row->{activity_id},
            type   => 'Announce',
            actor  => "$base/users/$username",
            object => $row->{object_url},
        },
        to => ['https://www.w3.org/ns/activitystreams#Public'],
    };

    my $followers = $db->query(
        'SELECT remote_inbox FROM followers
          WHERE local_user = ? AND accepted = TRUE AND remote_inbox IS NOT NULL',
        $username
    )->arrays;

    require FediVid::DeliveryQueue;
    for my $f (@$followers) {
        FediVid::DeliveryQueue::enqueue($db, $username, $f->[0], $undo);
    }

    $c->render(json => { ok => 1 });
}

sub index ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $exists = $db->query(
        'SELECT 1 FROM users WHERE username = ?', $username
    )->array;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $exists;

    my $rows = $db->query(
        'SELECT id, actor, object_url, is_remote, created_at
           FROM announces
          WHERE username = ?
          ORDER BY created_at DESC
          LIMIT 100',
        $username
    )->hashes;

    $c->render(json => {
        totalItems => scalar @$rows,
        items      => [ map {
            {
                id         => $_->{id} + 0,
                actor      => $_->{actor},
                object     => $_->{object_url},
                is_remote  => $_->{is_remote} ? 1 : 0,
                created_at => $_->{created_at},
            }
        } @$rows ],
    });
}

sub _authenticate_as ($c, $user) {
    my $username = $c->param('username');

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

sub _now_iso () {
    require POSIX;
    my @t = gmtime(time);
    return POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', @t);
}

1;
