package FediVid::Controller::ApiRemoteActors;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(decode_json);

sub show ($c) {
    my $handle = $c->param('handle');

    # handle can be: "alice@localhost:3000", "@alice@localhost:3000", or a full URL
    my $actor_url;
    if ($handle =~ m{\Ahttps?://}) {
        $actor_url = $handle;
    } else {
        $handle =~ s/\A\@//;
        my ($user, $host) = split /\@/, $handle, 2;
        return $c->render(json => { error => 'invalid_handle' }, status => 400)
            unless $user && $host;
        $actor_url = "http://$host/users/$user";
    }

    my $db = $c->pg->db;

    my $actor = $db->query(
        'SELECT url, actor, public_key, fetched_at FROM remote_actors WHERE url = ?',
        $actor_url
    )->hash;
    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $actor;

    my $doc = eval { decode_json($actor->{actor}) } || {};

    my $base = $c->config('base_url');

    # Videos this remote actor has posted
    my $videos = $db->query(
        q{
            SELECT id, title, description, object_id, video_url, media_type,
                   duration, width, height, published_at
              FROM (
                  SELECT DISTINCT ON (object_id)
                         id, title, description, object_id, video_url, media_type,
                         duration, width, height, published_at
                    FROM remote_videos
                   WHERE remote_actor = ?
                   ORDER BY object_id, id
              ) AS unique_remote
             ORDER BY published_at DESC NULLS LAST
             LIMIT 50
        },
        $actor_url
    )->hashes;

    my @items = map {
        {
            source           => 'remote',
            id               => $_->{id} + 0,
            username         => '@' . $actor_url =~ s{\Ahttps?://}{}r,
            remote_actor     => $actor_url,
            title            => $_->{title} // '',
            description      => $_->{description} // '',
            url              => $_->{video_url},
            hls_url          => undef,
            poster_url       => undef,
            duration         => $_->{duration} ? 0 + $_->{duration} : undef,
            width            => $_->{width}    ? 0 + $_->{width}    : undef,
            height           => $_->{height}   ? 0 + $_->{height}   : undef,
            transcode_status => 'ready',
            published_at     => $_->{published_at},
            like_count       => 0,
            comment_count    => 0,
        }
    } @$videos;

    my $short = $actor_url =~ s{\Ahttps?://}{}r;

    $c->render(json => {
        actor_url    => $actor_url,
        handle       => '@' . $short,
        name         => $doc->{name}              // $doc->{preferredUsername} // $short,
        summary      => $doc->{summary}           // '',
        icon         => ref $doc->{icon} eq 'HASH'
                        ? $doc->{icon}{url}
                        : ($doc->{icon} // undef),
        inbox        => $doc->{inbox}             // undef,
        published_at => $doc->{published}         // undef,
        fetched_at   => $actor->{fetched_at},
        video_count  => scalar @items,
        videos       => \@items,
    });
}

1;
