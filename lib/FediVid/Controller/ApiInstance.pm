package FediVid::Controller::ApiInstance;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub show ($c) {
    $c->render(json => {
        name        => $c->config('instance_name')        // 'FediVid',
        description => $c->config('instance_description') // '',
        base_url    => $c->config('base_url'),
        version     => '0.1',
        known_instances => $c->config('known_instances') // [],
    });
}

sub about ($c) {
    my $db   = $c->pg->db;
    my $base = $c->config('base_url');

    my $cats_raw = $c->config('instance_categories') // '';
    my @categories = grep { length } split /\|/, $cats_raw;
    @categories = map { s/^\s+|\s+$//gr } @categories;

    my $user_count = $db->query(
        'SELECT COUNT(*) AS n FROM users'
    )->hash->{n};

    my $video_count = $db->query(
        'SELECT COUNT(*) AS n FROM videos'
    )->hash->{n};

    my $local_videos = $db->query(
        'SELECT id, username, title, description, activity_id,
                duration_seconds, width, height, transcode_status, published_at
           FROM videos
          ORDER BY published_at DESC
          LIMIT 6'
    )->hashes;

    my @featured = map {
        {
            source           => 'local',
            id               => $_->{id} + 0,
            username         => $_->{username},
            title            => $_->{title},
            description      => $_->{description} // '',
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
            like_count       => 0,
            comment_count    => 0,
        }
    } @$local_videos;

    my $rules_raw = $c->config('instance_rules') // '';
    my @rules = grep { length } split /\|/, $rules_raw;
    @rules = map { s/^\s+|\s+$//gr } @rules;

    $c->render(json => {
        name        => $c->config('instance_name')        // 'FediVid',
        description => $c->config('instance_description') // '',
        contact     => $c->config('instance_contact')     // '',
        banner      => $c->config('instance_banner')      // '',
        base_url    => $base,
        feed_url    => "$base/feed.xml",
        version     => '0.1',
        user_count  => $user_count + 0,
        video_count => $video_count + 0,
        signup_open => $c->config('allow_signup') ? 1 : 0,
        rules       => \@rules,
        featured    => \@featured,
        known_instances => $c->config('known_instances') // [],
    });
}

sub actor ($c) {
    my $base = $c->config('base_url');
    my $name = $c->config('instance_name') // 'FediVid';
    my $desc = $c->config('instance_description') // '';

    my $actor_url = "$base/actor";

    $c->res->headers->content_type('application/activity+json');
    $c->render(data => Mojo::JSON::encode_json({
        '@context' => [
            'https://www.w3.org/ns/activitystreams',
            'https://w3id.org/security/v1',
        ],
        id           => $actor_url,
        type         => 'Service',
        name         => $name,
        summary      => $desc,
        url          => $base,
        inbox        => "$base/inbox",
        outbox       => "$base/outbox",
        followers    => "$base/followers",
        publicKey    => {
            id           => "$actor_url#main-key",
            owner        => $actor_url,
            publicKeyPem => $c->config('instance_public_key_pem') // '',
        },
    }));
}

1;
