package FediVid::Controller::ApiProfile;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub show ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $user = $db->query(
        'SELECT username, created_at FROM users WHERE username = ?',
        $username
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $user;

    my $base     = $c->config('base_url');
    my $actor_id = "$base/users/$username";

    my $following_count = $db->query(
        'SELECT COUNT(*) AS n FROM following
          WHERE local_user = ? AND accepted = TRUE',
        $username
    )->hash->{n};

    my $followers_count = $db->query(
        'SELECT COUNT(*) AS n FROM followers
          WHERE local_user = ? AND accepted = TRUE',
        $username
    )->hash->{n};

    my $video_count = $db->query(
        'SELECT COUNT(*) AS n FROM videos WHERE username = ?',
        $username
    )->hash->{n};

    # Are we (the session user) following them?
    my $viewer = eval {
        require FediVid::Controller::Sessions;
        FediVid::Controller::Sessions::_current_user($c);
    };

    my $you_follow = 0;
    if ($viewer && $viewer ne $username) {
        my $row = $db->query(
            'SELECT 1 FROM followers
              WHERE local_user = ? AND remote_actor = ? AND accepted = TRUE',
            $username, "$base/users/$viewer"
        )->array;
        $you_follow = $row ? 1 : 0;
    }

    $c->render(json => {
        username        => $user->{username},
        actor_id        => $actor_id,
        published_at    => $user->{created_at},
        following_count => $following_count + 0,
        followers_count => $followers_count + 0,
        video_count     => $video_count + 0,
        viewer          => $viewer,
        you_follow      => $you_follow,
    });
}

sub followers ($c) {
    my $username = $c->param('username');
    my $db       = $c->pg->db;

    my $exists = $db->query(
        'SELECT 1 FROM users WHERE username = ?', $username
    )->array;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $exists;

    my $base = $c->config('base_url');

    my $rows = $db->query(
        'SELECT remote_actor, accepted, created_at
           FROM followers
          WHERE local_user = ?
          ORDER BY created_at DESC
          LIMIT 200',
        $username
    )->hashes;

    $c->render(json => {
        totalItems => scalar @$rows,
        items      => [ map {
            {
                actor      => $_->{remote_actor},
                short      => _short_actor($_->{remote_actor}, $base),
                accepted   => $_->{accepted} ? 1 : 0,
                created_at => $_->{created_at},
            }
        } @$rows ],
    });
}

sub _short_actor ($actor, $base) {
    return 'unknown' unless defined $actor && length $actor;
    if ($actor =~ m{\A\Q$base\E/users/([^/]+)\z}) {
        return $1;
    }
    (my $s = $actor) =~ s{\Ahttps?://}{};
    return '@' . $s;
}

1;
