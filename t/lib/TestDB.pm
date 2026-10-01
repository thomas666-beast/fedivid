package TestDB;
use Mojo::Base -strict, -signatures;
use Exporter 'import';
our @EXPORT_OK = qw(setup_test_db);

sub setup_test_db ($app) {
    my $pg = $app->pg;
    $pg->db->query('DROP TABLE IF EXISTS worker_heartbeats CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS announces CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS messages CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS comments CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS rate_limits CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS notifications CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS remote_videos CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS deliveries CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS following CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS likes CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS outbox_activities CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS videos CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS followers CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS remote_actors CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS activities CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS users CASCADE');
    $pg->db->query('DROP TABLE IF EXISTS mojo_migrations CASCADE');
    $pg->migrations
       ->from_file($app->home->rel_file('migrations.sql'))
       ->migrate;
    return $pg;
}

1;
