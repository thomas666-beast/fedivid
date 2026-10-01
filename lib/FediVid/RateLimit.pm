package FediVid::RateLimit;
use Mojo::Base -strict, -signatures;

use Exporter 'import';
our @EXPORT_OK = qw(check_rate);

sub check_rate ($db, $key, $limit, $window_seconds) {
    my $row = $db->query(
        'INSERT INTO rate_limits (key, window_start, count)
              VALUES (?, NOW(), 1)
         ON CONFLICT (key) DO UPDATE
             SET count = CASE
                     WHEN rate_limits.window_start < NOW() - make_interval(secs => ?)
                         THEN 1
                     ELSE rate_limits.count + 1
                 END,
                 window_start = CASE
                     WHEN rate_limits.window_start < NOW() - make_interval(secs => ?)
                         THEN NOW()
                     ELSE rate_limits.window_start
                 END
         RETURNING count, EXTRACT(EPOCH FROM (window_start + make_interval(secs => ?) - NOW())) AS secs_until_reset',
        $key, $window_seconds, $window_seconds, $window_seconds
    )->hash;

    if ($row->{count} > $limit) {
        my $reset_in = int($row->{secs_until_reset} // 1);
        $reset_in = 1 if $reset_in < 1;
        return (0, $reset_in);
    }

    return (1, undef);
}

1;
