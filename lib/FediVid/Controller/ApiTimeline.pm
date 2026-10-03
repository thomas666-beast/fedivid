package FediVid::Controller::ApiTimeline;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use FediVid::Signature qw(verify_request verify_digest);
use FediVid::Auth qw(authenticate_as);

sub index ($c) {
    my $username = $c->param('username');
    my $cursor   = $c->param('cursor');
    my $limit    = $c->param('limit') // 50;
    $limit = 50 unless $limit =~ /^\d+$/ && $limit >= 1 && $limit <= 100;

    my $db = $c->pg->db;

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

    my $base = $c->config('base_url');

    my $following = $db->query(
        'SELECT remote_actor FROM following WHERE local_user = ?',
        $username
    )->arrays;

    my (@local_followed, @remote_followed);
    for my $row (@$following) {
        my $actor = $row->[0];
        if ($actor =~ m{\A\Q$base\E/users/([^/]+)\z}) {
            push @local_followed, $1;
        } else {
            push @remote_followed, $actor;
        }
    }

    my ($cursor_time, $cursor_id) = _parse_cursor($cursor);

    my @items;

    my $local_usernames = [$username, @local_followed];
    my $ph = join(',', ('?') x @$local_usernames);

    my $sql = "SELECT id, username, title, description, activity_id, duration_seconds,
                      width, height, transcode_status, published_at, tags,
                      (SELECT COUNT(*) FROM likes WHERE video_id = videos.id) AS like_count,
                      (SELECT COUNT(*) FROM comments WHERE video_id = videos.id) AS comment_count
                 FROM videos
                WHERE username IN ($ph)";
    my @params = @$local_usernames;

    if ($cursor_time) {
        $sql .= ' AND (published_at, id) < (?, ?)';
        push @params, $cursor_time, $cursor_id;
    }

    $sql .= ' ORDER BY published_at DESC, id DESC LIMIT ?';
    push @params, $limit + 1;

    my $local = $db->query($sql, @params)->hashes;

    for my $v (@$local) {
        push @items, {
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
        };
    }

    if (@remote_followed) {
        my $rp = join(',', ('?') x @remote_followed);
        my $rsql = qq{
            SELECT id, remote_actor, object_id, title, description,
                   video_url, media_type, duration, width, height, published_at, poster_url, tags
              FROM (
                  SELECT DISTINCT ON (object_id)
                         id, remote_actor, object_id, title, description,
                         video_url, media_type, duration, width, height, published_at, poster_url, tags
                    FROM remote_videos
                   WHERE local_user = ?
                     AND remote_actor IN ($rp)
                   ORDER BY object_id, id
              ) AS unique_remote
        };
        my @rparams = ($username, @remote_followed);

        if ($cursor_time) {
            $rsql .= ' WHERE (published_at, id) < (?, ?)';
            push @rparams, $cursor_time, $cursor_id;
        }

        $rsql .= ' ORDER BY published_at DESC NULLS LAST, id DESC LIMIT ?';
        push @rparams, $limit + 1;

        my $remote = $db->query($rsql, @rparams)->hashes;

        for my $v (@$remote) {
            push @items, {
                source           => 'remote',
                id               => $v->{id} + 0,
                username         => _short_actor($v->{remote_actor}),
                remote_actor     => $v->{remote_actor},
                title            => $v->{title} // '',
                description      => $v->{description} // '',
                tags             => _tags_array($v->{tags}),
                url              => $v->{video_url},
                hls_url          => undef,
                poster_url       => $v->{poster_url},
                duration         => $v->{duration} ? 0 + $v->{duration} : undef,
                width            => $v->{width}    ? 0 + $v->{width}    : undef,
                height           => $v->{height}   ? 0 + $v->{height}   : undef,
                transcode_status => 'ready',
                published_at     => $v->{published_at},
                like_count       => 0,
                comment_count    => 0,
            };
        }
    }

    @items = sort {
        my $a_key = $a->{published_at} // '';
        my $b_key = $b->{published_at} // '';
        $b_key cmp $a_key || $b->{id} <=> $a->{id}
    } @items;

    my $next_cursor;
    if (@items > $limit) {
        pop @items;
        my $last = $items[-1];
        $next_cursor = "$last->{published_at}|$last->{id}";
    }

    $c->render(json => {
        totalItems  => scalar @items,
        next_cursor => $next_cursor,
        items       => \@items,
    });
}

sub local ($c) {
    my $cursor = $c->param('cursor');
    my $limit  = $c->param('limit') // 50;
    my $tag    = $c->param('tag');

    $limit = 50 unless $limit =~ /^\d+$/ && $limit >= 1 && $limit <= 100;
    $tag = _normalize_tag($tag);

    my $db   = $c->pg->db;
    my $base = $c->config('base_url');

    my ($cursor_time, $cursor_id) = _parse_cursor($cursor);

    my $sql = 'SELECT id, username, title, description, activity_id, duration_seconds,
                      width, height, transcode_status, published_at, tags,
                      (SELECT COUNT(*) FROM likes WHERE video_id = videos.id) AS like_count,
                      (SELECT COUNT(*) FROM comments WHERE video_id = videos.id) AS comment_count
                 FROM videos';
    my @params;
    my @wheres;

    if ($tag) {
        push @wheres, '? = ANY(tags)';
        push @params, $tag;
    }

    if ($cursor_time) {
        push @wheres, '(published_at, id) < (?, ?)';
        push @params, $cursor_time, $cursor_id;
    }

    if (@wheres) {
        $sql .= ' WHERE ' . join(' AND ', @wheres);
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
            username         => $_->{username},
            title            => $_->{title},
            description      => $_->{description} // '',
            tags             => _tags_array($_->{tags}),
            url              => $_->{activity_id},
            hls_url          => $_->{transcode_status} eq 'ready'
                ? "$base/users/$_->{username}/videos/$_->{id}/hls/master.m3u8"
                : undef,
            poster_url       => $_->{transcode_status} eq 'ready'
                ? "$base/users/$_->{username}/videos/$_->{id}/hls/poster.jpg"
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

sub federated ($c) {
    my $cursor = $c->param('cursor');
    my $limit  = $c->param('limit') // 50;
    my $tag    = $c->param('tag');

    $limit = 50 unless $limit =~ /^\d+$/ && $limit >= 1 && $limit <= 100;
    $tag = _normalize_tag($tag);

    my $db   = $c->pg->db;
    my $base = $c->config('base_url');

    my ($cursor_time, $cursor_id) = _parse_cursor($cursor);

    my @items;

    my $lsql = 'SELECT id, username, title, description, activity_id, duration_seconds,
                       width, height, transcode_status, published_at, tags,
                       (SELECT COUNT(*) FROM likes WHERE video_id = videos.id) AS like_count,
                       (SELECT COUNT(*) FROM comments WHERE video_id = videos.id) AS comment_count
                  FROM videos';
    my @lparams;
    my @lwheres;

    if ($tag) {
        push @lwheres, '? = ANY(tags)';
        push @lparams, $tag;
    }

    if ($cursor_time) {
        push @lwheres, '(published_at, id) < (?, ?)';
        push @lparams, $cursor_time, $cursor_id;
    }

    if (@lwheres) {
        $lsql .= ' WHERE ' . join(' AND ', @lwheres);
    }

    $lsql .= ' ORDER BY published_at DESC, id DESC LIMIT ?';
    push @lparams, $limit + 1;

    my $local = $db->query($lsql, @lparams)->hashes;

    for my $v (@$local) {
        push @items, {
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
        };
    }

    my $rsql = q{
        SELECT id, remote_actor, object_id, title, description,
               video_url, media_type, duration, width, height, published_at, poster_url, tags
          FROM (
              SELECT DISTINCT ON (object_id)
                     id, remote_actor, object_id, title, description,
                     video_url, media_type, duration, width, height, published_at, poster_url, tags
                FROM remote_videos
               ORDER BY object_id, id
          ) AS unique_remote
    };
    my @rparams;
    my @rwheres;

    if ($tag) {
        push @rwheres, '? = ANY(tags)';
        push @rparams, $tag;
    }

    if ($cursor_time) {
        push @rwheres, '(published_at, id) < (?, ?)';
        push @rparams, $cursor_time, $cursor_id;
    }

    if (@rwheres) {
        $rsql .= ' WHERE ' . join(' AND ', @rwheres);
    }

    $rsql .= ' ORDER BY published_at DESC NULLS LAST, id DESC LIMIT ?';
    push @rparams, $limit + 1;

    my $remote = $db->query($rsql, @rparams)->hashes;

    for my $v (@$remote) {
        push @items, {
            source           => 'remote',
            id               => $v->{id} + 0,
            username         => _short_actor($v->{remote_actor}),
            remote_actor     => $v->{remote_actor},
            title            => $v->{title} // '',
            description      => $v->{description} // '',
            tags             => _tags_array($v->{tags}),
            url              => $v->{video_url},
            hls_url          => undef,
            poster_url       => $v->{poster_url},
            duration         => $v->{duration} ? 0 + $v->{duration} : undef,
            width            => $v->{width}    ? 0 + $v->{width}    : undef,
            height           => $v->{height}   ? 0 + $v->{height}   : undef,
            transcode_status => 'ready',
            published_at     => $v->{published_at},
            like_count       => 0,
            comment_count    => 0,
        };
    }

    @items = sort {
        my $a_key = $a->{published_at} // '';
        my $b_key = $b->{published_at} // '';
        $b_key cmp $a_key || $b->{id} <=> $a->{id}
    } @items;

    my $next_cursor;
    if (@items > $limit) {
        pop @items;
        my $last = $items[-1];
        $next_cursor = "$last->{published_at}|$last->{id}";
    }

    $c->render(json => {
        totalItems  => scalar @items,
        next_cursor => $next_cursor,
        items       => \@items,
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

sub _short_actor ($actor) {
    return '' unless defined $actor;
    (my $s = $actor) =~ s{\Ahttps?://}{};
    return $s;
}

sub _parse_cursor ($cursor) {
    return (undef, undef) unless defined $cursor && length $cursor;
    my ($t, $id) = split /\|/, $cursor, 2;
    return (undef, undef) unless $t && $id && $id =~ /^\d+$/;
    return ($t, $id);
}

sub _normalize_tag ($tag) {
    return undef unless defined $tag && length $tag;
    $tag = lc $tag;
    $tag =~ s/^#//;
    $tag =~ s/[^a-z0-9_\-]//g;
    return length($tag) >= 2 ? $tag : undef;
}

1;
