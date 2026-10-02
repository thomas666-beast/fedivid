package FediVid::Transcoder;
use Mojo::Base -strict, -signatures;
use Mojo::File qw(path);
use File::Path qw(make_path);

use Exporter 'import';
our @EXPORT_OK = qw(transcode);

sub transcode ($input, $out_dir) {
    return (undef, 'input does not exist') unless -f $input;

    _faststart($input);

    my $dir = path($out_dir);
    make_path($dir->to_string);

    my @renditions = (
        { name => '360p', width => 640,  height => 360,  bandwidth => 800_000 },
        { name => '720p', width => 1280, height => 720,  bandwidth => 2_800_000 },
    );

    for my $r (@renditions) {
        my $r_dir = $dir->child($r->{name});
        make_path($r_dir->to_string);

        my $vf = "scale=w=$r->{width}:h=$r->{height}:force_original_aspect_ratio=decrease";
        $vf .= ",pad=$r->{width}:$r->{height}:(ow-iw)/2:(oh-ih)/2";

        my @cmd = (
            'ffmpeg', '-y', '-loglevel', 'error',
            '-i', $input,
            '-vf', $vf,
            '-c:a', 'aac', '-ar', '48000', '-b:a', '128k',
            '-c:v', 'libx264', '-profile:v', 'main', '-preset', 'veryfast',
            '-crf', '23',
            '-g', '48', '-keyint_min', '48', '-sc_threshold', '0',
            '-hls_time', '6',
            '-hls_playlist_type', 'vod',
            '-hls_segment_filename', $r_dir->child('seg%04d.ts')->to_string,
            $r_dir->child('index.m3u8')->to_string,
        );

        my ($ok, $out) = _run(@cmd);
        return (undef, "ffmpeg failed for $r->{name}: $out") unless $ok;
    }

    # Extract poster frame — best-effort, some very short clips may fail
    _extract_poster($input, $dir->to_string);

    my $master = $dir->child('master.m3u8');
    my $content = "#EXTM3U\n#EXT-X-VERSION:3\n";
    for my $r (@renditions) {
        $content .= sprintf(
            "#EXT-X-STREAM-INF:BANDWIDTH=%d,RESOLUTION=%dx%d\n%s/index.m3u8\n",
            $r->{bandwidth}, $r->{width}, $r->{height}, $r->{name},
        );
    }
    $master->spurt($content);

    return ($master->to_string, undef);
}

sub _extract_poster ($input, $out_dir) {
    my $poster = path($out_dir, 'poster.jpg')->to_string;

    my @cmd = (
        'ffmpeg', '-y', '-loglevel', 'error',
        '-ss', '1',
        '-i', $input,
        '-frames:v', '1',
        '-vf', 'scale=640:-2',
        '-q:v', '3',
        $poster,
    );

    my ($ok, $out) = _run(@cmd);
    return ($ok ? $poster : undef, $ok ? undef : $out);
}

sub _faststart ($input) {
    return unless $input =~ /\.mp4\z/i;

    my $tmp = "$input.faststart.tmp";
    my $exit = system('ffmpeg', '-y', '-loglevel', 'error',
        '-i', $input,
        '-c', 'copy',
        '-movflags', 'faststart',
        '-f', 'mp4',
        $tmp,
    );
    $exit >>= 8;

    if ($exit == 0 && -f $tmp && -s $tmp > 1000) {
        rename $tmp, $input;
    } else {
        unlink $tmp;
    }
}

# Run a command without going through a shell.
# Returns (ok_boolean, combined_output_string).
sub _run (@cmd) {
    my $out = '';
    my $pid = open my $fh, '-|';
    if (!defined $pid) {
        return (0, "fork failed: $!");
    }
    if ($pid == 0) {
        open STDERR, '>&', \*STDOUT or die "dup stderr: $!";
        exec @cmd or die "exec failed: $!";
        exit 127;
    }
    while (my $line = <$fh>) {
        $out .= $line;
    }
    close $fh;
    my $exit = $? >> 8;
    return ($exit == 0, $out);
}

1;
