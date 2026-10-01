#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;
use FediVid::WorkerHeartbeat qw(beat);
use Mojo::File qw(path);
use File::Path qw(make_path);

my $app = FediVid->new;
my $db  = $app->pg->db;
my $ua  = $app->ua;

my $base_dir = $app->config('upload_dir') // 'uploads';

my $loop    = grep { $_ eq '--loop' } @ARGV;
my $verbose = grep { $_ eq '--verbose' } @ARGV;

sub log_msg ($msg) {
    my @t = localtime;
    printf "[%04d-%02d-%02d %02d:%02d:%02d] %s\n",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0], $msg;
}

sub debug_msg ($msg) {
    return unless $verbose;
    log_msg("  [debug] $msg");
}

log_msg("poster worker starting" . ($loop ? " (loop mode)" : ""));
beat($db, 'poster', 0);

while (1) {
    my $row = $db->query(
        "SELECT id, remote_actor, object_id, video_url
           FROM remote_videos
          WHERE poster_path IS NULL
            AND object_id IS NOT NULL
          ORDER BY id
          LIMIT 1
          FOR UPDATE SKIP LOCKED"
    )->hash;

    if (!$row) {
        beat($db, 'poster', 0);
        last unless $loop;
        sleep 10;
        next;
    }

    my $dir = path($base_dir, 'remote-posters');
    make_path($dir->to_string);

    my $poster = $dir->child("$row->{id}.jpg")->to_string;

    log_msg("poster for remote video $row->{id}");
    debug_msg("object_id: $row->{object_id}");

    # Try poster URLs derived from the object_id
    my @candidates = _poster_candidates($row->{object_id});
    my $ok = 0;

    for my $url (@candidates) {
        debug_msg("trying: $url");
        my $tx = $ua->get($url);
        my $code = $tx->res->code // 0;
        next unless $code == 200;

        my $body = $tx->res->body;
        next unless defined $body && length $body > 200;

        # Sanity check: JPEG magic bytes
        next unless substr($body, 0, 2) eq "\xFF\xD8";

        path($poster)->spurt($body);
        $ok = 1;
        last;
    }

    if ($ok) {
        $db->query(
            'UPDATE remote_videos SET poster_path = ? WHERE id = ?',
            $poster, $row->{id}
        );
        log_msg("  done: $poster");
        beat($db, 'poster', 1);
        next;
    }

    $db->query(
        "UPDATE remote_videos SET poster_path = '' WHERE id = ?",
        $row->{id}
    );
    log_msg("  failed (no poster found on remote)");
    beat($db, 'poster', 1);
}

log_msg("poster worker exiting");

sub _poster_candidates ($object_id) {
    my @urls;

    # Common patterns:
    #   http://host/users/alice/videos/FILE.mp4
    #     → http://host/users/alice/videos/FILE/hls/poster.jpg   (our convention by basename)
    #     → http://host/users/alice/videos/<id>/hls/poster.jpg   (our convention by id)
    #   https://host/users/alice/videos/<uuid>
    #     → https://host/users/alice/videos/<uuid>/hls/poster.jpg

    # Pattern 1: object_id + /hls/poster.jpg
    push @urls, "$object_id/hls/poster.jpg";

    # Pattern 2: strip file extension, add /hls/poster.jpg
    if ($object_id =~ m{\A(.+?)\.\w+\z}) {
        push @urls, "$1/hls/poster.jpg";
    }

    # Pattern 3: replace /videos/FILE with /videos/FILE/hls/poster.jpg
    if ($object_id =~ m{(.+?/videos/[^/]+)$}) {
        push @urls, "$1/hls/poster.jpg";
    }

    # Pattern 4: PeerTube convention — object_id + /preview.jpg
    push @urls, "$object_id/preview.jpg";

    return @urls;
}
