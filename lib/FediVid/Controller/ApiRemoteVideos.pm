package FediVid::Controller::ApiRemoteVideos;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub show ($c) {
    my $id = $c->param('id');
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $id =~ /^\d+$/;

    my $db = $c->pg->db;

    my $v = $db->query(
        'SELECT id, local_user, remote_actor, object_id, title, description,
                video_url, media_type, duration, width, height, published_at, poster_url, tags
           FROM remote_videos
          WHERE id = ?',
        $id
    )->hash;

    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $v;

    my $comment_count = $db->query(
        'SELECT COUNT(*) AS n FROM comments WHERE video_actor = ?',
        $v->{object_id}
    )->hash->{n};

    my $boost_count = $db->query(
        'SELECT COUNT(*) AS n FROM announces WHERE object_url = ?',
        $v->{object_id}
    )->hash->{n};

    my $short_actor = $v->{remote_actor};
    $short_actor =~ s{\Ahttps?://}{};

    # Look up the author's icon URL for the avatar
    my $author_icon;
    my $actor_row = $db->query(
        'SELECT actor FROM remote_actors WHERE url = ?',
        $v->{remote_actor}
    )->hash;
    if ($actor_row) {
        my $doc = eval { Mojo::JSON::decode_json($actor_row->{actor}) } || {};
        $author_icon = ref $doc->{icon} eq 'HASH'
            ? $doc->{icon}{url}
            : ($doc->{icon} // undef);
    }

    $c->render(json => {
        source           => 'remote',
        id               => $v->{id} + 0,
        username         => '@' . $short_actor,
        remote_actor     => $v->{remote_actor},
        object_id        => $v->{object_id},
        title            => $v->{title} // '',
        description      => $v->{description} // '',
        tags             => _tags_array($v->{tags}),
        url              => $v->{video_url},
        hls_url          => undef,
        poster_url       => $v->{poster_url},
        author_icon      => $author_icon,
        duration         => $v->{duration} ? 0 + $v->{duration} : undef,
        width            => $v->{width}    ? 0 + $v->{width}    : undef,
        height           => $v->{height}   ? 0 + $v->{height}   : undef,
        media_type       => $v->{media_type} // 'video/mp4',
        transcode_status => 'ready',
        published_at     => $v->{published_at},
        like_count       => 0,
        comment_count    => $comment_count + 0,
        boost_count      => $boost_count + 0,
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

1;
