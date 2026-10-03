#!/usr/bin/env perl
use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use FediVid;
use FediVid::Password qw(hash_password);
use Crypt::OpenSSL::RSA;
use Mojo::JSON qw(encode_json);
use Time::HiRes qw(time);

# ---- Options ----
my $users_count = 10_000;
my $password    = '1234pass';
my $reset       = 0;

for (my $i = 0; $i < @ARGV; $i++) {
    my $arg = $ARGV[$i];
    if    ($arg eq '--reset')     { $reset = 1 }
    elsif ($arg eq '--users' && $ARGV[$i+1])   { $users_count = $ARGV[++$i] }
    elsif ($arg eq '--password' && $ARGV[$i+1]) { $password = $ARGV[++$i] }
    elsif ($arg eq '--help' || $arg eq '-h') {
        print <<"USAGE";
Usage: perl script/seed.pl [--reset] [--users N] [--password PASS]

  --reset         TRUNCATE all app tables before seeding
  --users N       number of users to create (default: 10,000)
  --password PASS password for all seeded users (default: "1234pass")
USAGE
        exit 0;
    }
}

my $app = FediVid->new;
my $db  = $app->pg->db;

print "Seeding against $app->{config}{database_url}\n";
print "Users: $users_count\n";
print "Password: $password\n";
print "Mode: ", ($reset ? 'RESET + seed' : 'additive'), "\n\n";

if ($reset) {
    print "Truncating all app tables...\n";
    $db->query('TRUNCATE users CASCADE');
    $db->query('TRUNCATE rate_limits');
    $db->query('TRUNCATE worker_heartbeats');
    print "  done\n\n";
}

# ---- Shared RSA key for all seeded users (dev only!) ----
print "Generating one shared RSA key (this takes a few seconds)...\n";
my $rsa = Crypt::OpenSSL::RSA->generate_key(2048);
my $priv_pem = $rsa->get_private_key_string();
my $pub_pem  = $rsa->get_public_key_x509_string();
print "  done\n\n";

print "Hashing password once (bcrypt cost 12, ~0.3s)...\n";
my $pass_hash = hash_password($password);
print "  done\n\n";

# ---- Sample data pools ----
my @title_words = qw(
    cooking guitar piano hiking sunset mountain ocean forest city sky
    sunrise night rain snow winter summer spring autumn coffee tea book
    music dance song poem story travel adventure festival
);

# Each shape is a sub that takes two words and returns a title string.
my @title_shapes = (
    sub { "$_[0] $_[1]" },
    sub { "My $_[0] $_[1]" },
    sub { "$_[0] in the $_[1]" },
    sub { "Best $_[0] ever" },
    sub { "How to $_[0] $_[1]" },
    sub { "$_[0]: a $_[1] story" },
);

my @comment_phrases = (
    'nice', 'cool', 'great video', 'love it', 'amazing',
    'thanks for sharing', 'this is great', 'wow', 'so good',
    'lol', 'interesting', 'very helpful', 'keep it up',
    'first time here', 'subscribed', 'hello from the fediverse',
);

my @tag_pool = qw(music tech cooking gaming vlog sports news diy musicvibes);

sub _random_title {
    my $shape = $title_shapes[ int rand @title_shapes ];
    my $w1 = $title_words[ int rand @title_words ];
    my $w2 = $title_words[ int rand @title_words ];
    return $shape->($w1, $w2);
}

# ---- Main seed loop ----
my $t0 = time;
my $batch_size = 500;
my $created_users = 0;

print "Creating users...\n";

my @new_ids;
my @new_usernames;

for (my $start = 1; $start <= $users_count; $start += $batch_size) {
    my $end = $start + $batch_size - 1;
    $end = $users_count if $end > $users_count;

    my $tx = $db->begin;

    my @values;
    my @params;
    for my $n ($start .. $end) {
        my $username = sprintf('user%05d', $n);
        push @values, '(?, ?, ?, ?)';
        push @params, $username, $priv_pem, $pub_pem, $pass_hash;
        push @new_usernames, $username;
    }

    $db->query(
        "INSERT INTO users (username, private_key_pem, public_key_pem, password_hash)
         VALUES " . join(',', @values) . "
         ON CONFLICT (username) DO NOTHING",
        @params
    );

    # Fetch back the IDs we just created (or that already existed)
    my @batch_names = @new_usernames[ $start - 1 .. $end - 1 ];
    my $ph = join(',', ('?') x @batch_names);
    my $rows = $db->query(
        "SELECT id, username FROM users WHERE username IN ($ph)",
        @batch_names
    )->hashes;
    push @new_ids, $_->{id} for @$rows;

    $tx->commit;

    $created_users += ($end - $start + 1);
    my $elapsed = time - $t0;
    printf "  users: %6d / %6d  (%.1fs)\n", $created_users, $users_count, $elapsed;
}

print "  done: ", scalar(@new_ids), " users available\n\n";

# ---- Create videos ----
my $videos_target = int(@new_ids * 1.5);
print "Creating ~$videos_target videos...\n";

my @video_ids;
my $videos_created = 0;
my $t1 = time;

for (my $i = 0; $i < $videos_target; $i += $batch_size) {
    my $batch_end = $i + $batch_size - 1;
    $batch_end = $videos_target - 1 if $batch_end >= $videos_target;

    my $tx = $db->begin;
    my @values;
    my @params;

    for my $j ($i .. $batch_end) {
        my $owner_idx = int(rand(@new_ids));
        my $username  = $new_usernames[$owner_idx];

        my $title = _random_title();

        my @tags = map { $tag_pool[ int rand @tag_pool ] } 1 .. int(rand(4));
        my $tags_pg = '{' . join(',', @tags) . '}';

        my $basename  = sprintf('%d-%d.mp4', time + $j, int(rand(1_000_000)));
        my $activity_id = "http://localhost:3000/users/$username/videos/$basename";
        my $status = rand() < 0.9 ? 'ready' : 'pending';

        push @values, '(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?::text[])';
        push @params,
            $username,
            $title,
            'Seeded video',
            'video/mp4',
            "/tmp/seed/$basename",
            int(rand(50 * 1024 * 1024)) + 1_000_000,
            $activity_id,
            $status,
            int(rand(600)) + 5,
            640, 480,
            $tags_pg;
    }

    my $res = $db->query(
        "INSERT INTO videos
             (username, title, description, content_type, file_path, size_bytes,
              activity_id, transcode_status, duration_seconds, width, height, tags)
         VALUES " . join(',', @values) . "
         RETURNING id",
        @params
    )->arrays;

    push @video_ids, $_->[0] for @$res;
    $tx->commit;

    $videos_created += scalar(@$res);
    my $elapsed = time - $t1;
    printf "  videos: %6d / %6d  (%.1fs)\n", $videos_created, $videos_target, $elapsed;
}

print "  done: ", scalar(@video_ids), " videos\n\n";

# ---- Likes ----
my $likes_target = int(@video_ids * 7);
print "Creating ~$likes_target likes...\n";

my $likes_created = 0;
my $t2 = time;

for (my $i = 0; $i < $likes_target; $i += $batch_size) {
    my $batch_end = $i + $batch_size - 1;
    $batch_end = $likes_target - 1 if $batch_end >= $likes_target;

    my $tx = $db->begin;
    my @values;
    my @params;

    for my $j ($i .. $batch_end) {
        my $video_id = $video_ids[ int rand @video_ids ];
        my $actor    = "http://localhost:3000/users/user" . sprintf('%05d', int(rand(@new_ids)) + 1);
        my $activity = "urn:seed:like:$j";

        push @values, '(?, ?, ?)';
        push @params, $video_id, $actor, $activity;
    }

    $db->query(
        "INSERT INTO likes (video_id, remote_actor, activity_id)
         VALUES " . join(',', @values) . "
         ON CONFLICT DO NOTHING",
        @params
    );

    $tx->commit;

    $likes_created += ($batch_end - $i + 1);
    my $elapsed = time - $t2;
    printf "  likes: %7d / %7d  (%.1fs)\n", $likes_created, $likes_target, $elapsed;
    last if $elapsed > 300;
}

print "  done\n\n";

# ---- Comments ----
my $comments_target = int(@video_ids * 3);
print "Creating ~$comments_target comments...\n";

my $comments_created = 0;
my $t3 = time;

for (my $i = 0; $i < $comments_target; $i += $batch_size) {
    my $batch_end = $i + $batch_size - 1;
    $batch_end = $comments_target - 1 if $batch_end >= $comments_target;

    my $tx = $db->begin;
    my @values;
    my @params;

    for my $j ($i .. $batch_end) {
        my $video_id = $video_ids[ int rand @video_ids ];
        my $body = $comment_phrases[ int rand @comment_phrases ];
        my $author = "http://localhost:3000/users/user" . sprintf('%05d', int(rand(@new_ids)) + 1);
        my $activity = "urn:seed:comment:$j";

        push @values, '(?, ?, ?, ?, ?, FALSE)';
        push @params, $video_id, $author, $author, $body, $activity;
    }

    $db->query(
        "INSERT INTO comments (video_id, video_actor, author_actor, body, activity_id, is_remote)
         VALUES " . join(',', @values) . "
         ON CONFLICT DO NOTHING",
        @params
    );

    $tx->commit;

    $comments_created += ($batch_end - $i + 1);
    my $elapsed = time - $t3;
    printf "  comments: %6d / %6d  (%.1fs)\n", $comments_created, $comments_target, $elapsed;
}

print "  done\n\n";

# ---- Follows ----
my $follows_target = int(@new_ids * 15);
print "Creating ~$follows_target follow edges...\n";

my $follows_created = 0;
my $t4 = time;

for (my $i = 0; $i < $follows_target; $i += $batch_size) {
    my $batch_end = $i + $batch_size - 1;
    $batch_end = $follows_target - 1 if $batch_end >= $follows_target;

    my $tx = $db->begin;
    my @values;
    my @params;

    for my $j ($i .. $batch_end) {
        my $follower_idx = int(rand(@new_ids));
        my $target_idx = int(rand(@new_ids));
        next if $follower_idx == $target_idx;

        my $follower = $new_usernames[$follower_idx];
        my $target   = $new_usernames[$target_idx];
        my $target_actor = "http://localhost:3000/users/$target";

        push @values, '(?, ?, NULL, TRUE)';
        push @params, $follower, $target_actor;

        push @values, '(?, ?, NULL, TRUE)';
        push @params, $target, "http://localhost:3000/users/$follower";
    }

    if (@values) {
        $db->query(
            "INSERT INTO followers (local_user, remote_actor, remote_inbox, accepted)
             VALUES " . join(',', @values) . "
             ON CONFLICT DO NOTHING",
            @params
        );

        $db->query(
            "INSERT INTO following (local_user, remote_actor, remote_inbox, accepted)
             VALUES " . join(',', @values) . "
             ON CONFLICT DO NOTHING",
            @params
        );
    }

    $tx->commit;

    $follows_created += ($batch_end - $i + 1);
    my $elapsed = time - $t4;
    printf "  follows: %7d / %7d  (%.1fs)\n", $follows_created, $follows_target, $elapsed;
}

print "  done\n\n";

# ---- Notifications ----
my $notif_target = 50_000;
print "Creating $notif_target notifications...\n";

my $notif_created = 0;
my $t5 = time;

for (my $i = 0; $i < $notif_target; $i += $batch_size) {
    my $batch_end = $i + $batch_size - 1;
    $batch_end = $notif_target - 1 if $batch_end >= $notif_target;

    my $tx = $db->begin;
    my @values;
    my @params;

    for my $j ($i .. $batch_end) {
        my $recipient = $new_usernames[ int rand(@new_ids) ];
        my $actor = "http://localhost:3000/users/user" . sprintf('%05d', int(rand(@new_ids)) + 1);
        my $type = (qw(follow like comment announce create))[ int rand 5 ];

        push @values, '(?, ?, ?, NULL, NULL, NULL)';
        push @params, $recipient, $type, $actor;
    }

    $db->query(
        "INSERT INTO notifications (username, type, actor, object_id, object_url, video_id)
         VALUES " . join(',', @values),
        @params
    );

    $tx->commit;

    $notif_created += ($batch_end - $i + 1);
    my $elapsed = time - $t5;
    printf "  notifications: %7d / %7d  (%.1fs)\n", $notif_created, $notif_target, $elapsed;
}

print "  done\n\n";

# ---- Summary ----
my $total = time - $t0;
print "=" x 60, "\n";
print "Seed complete in ", sprintf('%.1fs', $total), "\n";
print "=" x 60, "\n";

my $counts = $db->query(<<SQL)->hash;
    SELECT
        (SELECT COUNT(*) FROM users)         AS users,
        (SELECT COUNT(*) FROM videos)        AS videos,
        (SELECT COUNT(*) FROM likes)         AS likes,
        (SELECT COUNT(*) FROM comments)      AS comments,
        (SELECT COUNT(*) FROM followers)     AS followers,
        (SELECT COUNT(*) FROM following)     AS following,
        (SELECT COUNT(*) FROM notifications) AS notifications
SQL

printf "  %-15s %10d\n", $_, $counts->{$_} for sort keys %$counts;
print "\n";
print "Warning: all seeded users share the same RSA keypair.\n";
print "This is fine for a local dev instance, but never do this in production.\n";
