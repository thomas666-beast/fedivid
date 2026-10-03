package FediVid::Controller::ApiNotifications;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use FediVid::Signature qw(verify_request verify_digest);
use FediVid::Auth qw(authenticate_as);

sub index ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT private_key_pem, public_key_pem FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my ($authed, $auth_err) = authenticate_as($c, $user, $username);
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

    my ($authed, $auth_err) = authenticate_as($c, $user, $username);
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

1;
