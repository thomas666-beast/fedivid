package FediVid::Controller::ApiSearch;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub index ($c) {
    my $q     = $c->param('q') // '';
    my $type  = $c->param('type') // 'all';
    my $limit = $c->param('limit') // 20;

    $q =~ s/^\s+|\s+$//g;
    return $c->render(json => { error => 'empty_query' }, status => 400)
        unless length($q) >= 2;
    return $c->render(json => { error => 'query_too_long' }, status => 400)
        if length($q) > 200;

    $limit = 20 unless $limit =~ /^\d+$/ && $limit >= 1;
    $limit = 50 if $limit > 50;

    $type = 'all' unless $type =~ /\A(videos|users|comments|all)\z/;

    my $db = $c->pg->db;
    my $pattern = '%' . _escape_like($q) . '%';

    my $base = $c->config('base_url');

    my %out = (
        query    => $q,
        videos   => [],
        users    => [],
        comments => [],
    );

    if ($type eq 'videos' || $type eq 'all') {
        my $rows = $db->query(
            "SELECT id, username, title, description, activity_id,
                    duration_seconds, width, height, transcode_status,
                    published_at
               FROM videos
              WHERE title ILIKE ?
                 OR description ILIKE ?
              ORDER BY published_at DESC
              LIMIT ?",
            $pattern, $pattern, $limit
        )->hashes;

        $out{videos} = [ map {
            {
                id               => $_->{id} + 0,
                username         => $_->{username},
                title            => $_->{title},
                description      => $_->{description} // '',
                url              => $_->{activity_id},
                hls_url          => $_->{transcode_status} eq 'ready'
                    ? "$base/users/$_->{username}/videos/$_->{id}/hls/master.m3u8"
                    : undef,
                duration         => $_->{duration_seconds} ? 0 + $_->{duration_seconds} : undef,
                width            => $_->{width}  ? 0 + $_->{width}  : undef,
                height           => $_->{height} ? 0 + $_->{height} : undef,
                transcode_status => $_->{transcode_status},
                published_at     => $_->{published_at},
            }
        } @$rows ];
    }

    if ($type eq 'users' || $type eq 'all') {
        my $rows = $db->query(
            "SELECT u.username, u.created_at,
                    (SELECT COUNT(*) FROM videos v WHERE v.username = u.username) AS video_count,
                    (SELECT COUNT(*) FROM followers f WHERE f.local_user = u.username AND f.accepted) AS followers_count
               FROM users u
              WHERE u.username ILIKE ?
              ORDER BY u.username ASC
              LIMIT ?",
            $pattern, $limit
        )->hashes;

        $out{users} = [ map {
            {
                username        => $_->{username},
                actor_id        => "$base/users/$_->{username}",
                video_count     => $_->{video_count} + 0,
                followers_count => $_->{followers_count} + 0,
                created_at      => $_->{created_at},
            }
        } @$rows ];
    }

    if ($type eq 'comments' || $type eq 'all') {
        my $rows = $db->query(
            "SELECT c.id, c.author_actor, c.body, c.is_remote, c.created_at,
                    v.id AS video_id, v.username AS video_username, v.activity_id AS video_actor
               FROM comments c
               LEFT JOIN videos v ON v.id = c.video_id
              WHERE c.body ILIKE ?
              ORDER BY c.created_at DESC
              LIMIT ?",
            $pattern, $limit
        )->hashes;

        $out{comments} = [ map {
            my $display_author;
            if ($_->{author_actor} =~ m{\A\Q$base\E/users/([^/]+)\z}) {
                $display_author = $1;
            } else {
                (my $short = $_->{author_actor}) =~ s{\Ahttps?://}{};
                $display_author = '@' . $short;
            }
            {
                id         => $_->{id} + 0,
                username   => $display_author,
                body       => $_->{body},
                is_remote  => $_->{is_remote} ? 1 : 0,
                created_at => $_->{created_at},
                video_id   => $_->{video_id} ? $_->{video_id} + 0 : undef,
                video_user => $_->{video_username},
                video_url  => $_->{video_actor},
            }
        } @$rows ];
    }

    $c->render(json => \%out);
}

sub _escape_like ($s) {
    $s =~ s/\\/\\\\/g;
    $s =~ s/%/\\%/g;
    $s =~ s/_/\\_/g;
    return $s;
}

1;
