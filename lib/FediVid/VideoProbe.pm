package FediVid::VideoProbe;
use Mojo::Base -strict, -signatures;
use Mojo::JSON qw(decode_json);

use Exporter 'import';
our @EXPORT_OK = qw(probe_video);

sub probe_video ($path) {
    return (undef, 'file does not exist') unless -f $path;

    my @cmd = (
        'ffprobe',
        '-v', 'error',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        $path,
    );

    my ($exit, $out) = _run(@cmd);
    return (undef, "ffprobe exit $exit: $out") if $exit != 0;

    my $data = eval { decode_json($out) };
    return (undef, 'ffprobe returned invalid JSON') unless $data;

    my $streams = $data->{streams} // [];
    my ($video) = grep { ($_->{codec_type} // '') eq 'video' } @$streams;
    return (undef, 'no video stream found') unless $video;

    my $duration = $data->{format}{duration} // $video->{duration};
    return (undef, 'no duration reported') unless defined $duration;

    my $width  = $video->{width}  // 0;
    my $height = $video->{height} // 0;
    return (undef, 'no dimensions reported') unless $width && $height;

    return ({
        duration_seconds => 0 + $duration,
        width            => 0 + $width,
        height           => 0 + $height,
        codec            => $video->{codec_name} // 'unknown',
    }, undef);
}

# Run a command without going through a shell.
# Returns (exit_code, combined_output_string).
sub _run (@cmd) {
    my $out = '';
    my $pid = open my $fh, '-|';
    if (!defined $pid) {
        return (127, "fork failed: $!");
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
    return ($? >> 8, $out);
}

1;
