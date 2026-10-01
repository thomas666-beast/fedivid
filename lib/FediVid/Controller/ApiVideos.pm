package FediVid::Controller::ApiVideos;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($c) {
    my $username = $c->param('username');
    my $cursor   = $c->param('cursor');
    my $limit    = $c->param('limit') // 50;

    $limit = 50 unless $limit =~ /^\d+$/ && $limit >= 1 && $limit <= 100;

    my $db = $c->pg->db;

    my $exists = $db->query(
        'SELECT 1 FROM users WHERE username = ?', $username
    )->array;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $exists;

    my $base = $c->config('base_url');

    my ($cursor_time, $cursor_id) = _parse_cursor($cursor);

    my $sql = 'SELECT id, title, description, activity_id, duration_seconds,
                      width, height, transcode_status, published_at, tags,
                      (SELECT COUNT(*) FROM likes WHERE video_id = videos.id) AS like_count,
                      (SELECT COUNT(*) FROM comments WHERE video_id = videos.id) AS comment_count
                 FROM videos
                WHERE username = ?';
    my @params = ($username);

    if ($cursor_time) {
        $sql .= ' AND (published_at, id) < (?, ?)';
        push @params, $cursor_time, $cursor_id;
    }

    $sql .= ' ORDER BY published_at DESC, id DESC LIMIT ?';
    push @params, $limit + 1;

    my $rows = $db->query($sql, @params)->hashes;

    my $next_cursor;
    if (@$rows > $limit) {
        pop @$rows;
        my $last = $rows->[-1];
        $next_cursor = "$last->{published_at}|$last->{id}";
    }

    my @items = map {
        {
            source           => 'local',
            id               => $_->{id} + 0,
            username         => $username,
            title            => $_->{title},
            description      => $_->{description} // '',
            tags             => _tags_array($_->{tags}),
            url              => $_->{activity_id},
            hls_url          => $_->{transcode_status} eq 'ready'
                ? "$base/users/$username/videos/$_->{id}/hls/master.m3u8"
                : undef,
            poster_url       => $_->{transcode_status} eq 'ready'
                ? "$base/users/$username/videos/$_->{id}/hls/poster.jpg"
                : undef,
            duration         => $_->{duration_seconds} ? 0 + $_->{duration_seconds} : undef,
            width            => $_->{width}  ? 0 + $_->{width}  : undef,
            height           => $_->{height} ? 0 + $_->{height} : undef,
            transcode_status => $_->{transcode_status},
            published_at     => $_->{published_at},
            like_count       => $_->{like_count} + 0,
            comment_count    => $_->{comment_count} + 0,
        }
    } @$rows;

    $c->render(json => {
        totalItems  => scalar @items,
        next_cursor => $next_cursor,
        items       => \@items,
    });
}

sub show ($c) {
    my $username = $c->param('username');
    my $id       = $c->param('id');
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $id =~ /^\d+$/;

    my $db = $c->pg->db;

    my $exists = $db->query(
        'SELECT 1 FROM users WHERE username = ?', $username
    )->array;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $exists;

    my $v = $db->query(
        'SELECT id, username, title, description, activity_id, tags,
                duration_seconds, width, height, transcode_status,
                published_at,
                (SELECT COUNT(*) FROM likes WHERE video_id = videos.id) AS like_count,
                (SELECT COUNT(*) FROM comments WHERE video_id = videos.id) AS comment_count,
                (SELECT COUNT(*) FROM announces WHERE object_url = videos.activity_id) AS boost_count
           FROM videos
          WHERE id = ?',
        $id
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $v;

    my $base = $c->config('base_url');

    $c->render(json => {
        source           => 'local',
        id               => $v->{id} + 0,
        username         => $v->{username},
        title            => $v->{title},
        description      => $v->{description} // '',
        tags             => _tags_array($v->{tags}),
        url              => $v->{activity_id},
        hls_url          => $v->{transcode_status} eq 'ready'
            ? "$base/users/$v->{username}/videos/$v->{id}/hls/master.m3u8"
            : undef,
        poster_url       => $v->{transcode_status} eq 'ready'
            ? "$base/users/$v->{username}/videos/$v->{id}/hls/poster.jpg"
            : undef,
        duration         => $v->{duration_seconds} ? 0 + $v->{duration_seconds} : undef,
        width            => $v->{width}  ? 0 + $v->{width}  : undef,
        height           => $v->{height} ? 0 + $v->{height} : undef,
        transcode_status => $v->{transcode_status},
        published_at     => $v->{published_at},
        like_count       => $v->{like_count} + 0,
        comment_count    => $v->{comment_count} + 0,
        boost_count      => $v->{boost_count} + 0,
    });
}

sub like ($c) {
    my $username = $c->param('username');
    my $video_id = $c->param('id');
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

    my $video = $db->query(
        'SELECT id FROM videos WHERE id = ?', $video_id
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video;

    my $base   = $c->config('base_url');
    my $actor  = "$base/users/$username";
    my $method = $c->req->method;

    if ($method eq 'DELETE') {
        $db->query(
            'DELETE FROM likes WHERE video_id = ? AND remote_actor = ?',
            $video->{id}, $actor
        );
        return $c->render(json => { liked => 0 });
    }

    $db->query(
        'INSERT INTO likes (video_id, remote_actor, activity_id)
              VALUES (?, ?, ?)
         ON CONFLICT (video_id, remote_actor) DO NOTHING',
        $video->{id}, $actor,
        "$base/users/$username#likes/" . time . '-' . int(rand(1_000_000))
    );

    $c->render(json => { liked => 1 });
}

sub like_status ($c) {
    my $username = $c->param('username');
    my $video_id = $c->param('id');
    my $db       = $c->pg->db;

    my $video = $db->query(
        'SELECT id FROM videos WHERE id = ?', $video_id
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $video;

    my $count = $db->query(
        'SELECT COUNT(*) AS n FROM likes WHERE video_id = ?',
        $video->{id}
    )->hash->{n};

    my $base  = $c->config('base_url');
    my $actor = "$base/users/$username";

    my $is_liked = $db->query(
        'SELECT 1 FROM likes WHERE video_id = ? AND remote_actor = ?',
        $video->{id}, $actor
    )->array;

    $c->render(json => {
        count => $count + 0,
        liked => $is_liked ? 1 : 0,
    });
}

sub _tags_array ($raw) {
    return [] unless defined $raw;
    return $raw if ref $raw eq 'ARRAY';
    return [] if $raw eq '{}';
    $raw =~ s/^\{//;
    $raw =~ s/\}$//;
    return [ split /,/, $raw ];
}

sub _parse_cursor ($cursor) {
    return (undef, undef) unless defined $cursor && length $cursor;
    my ($t, $id) = split /\|/, $cursor, 2;
    return (undef, undef) unless $t && $id && $id =~ /^\d+$/;
    return ($t, $id);
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

    require FediVid::Signature;
    my ($sig_ok, $sig_err) = FediVid::Signature::verify_request($c->req, $user->{public_key_pem});
    return (0, "signature: $sig_err") unless $sig_ok;

    my ($digest_ok, $digest_err) = FediVid::Signature::verify_digest($c->req);
    return (0, "digest: $digest_err") unless $digest_ok;

    return (1, undef);
}

1;
