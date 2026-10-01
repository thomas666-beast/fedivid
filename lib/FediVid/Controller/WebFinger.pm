package FediVid::Controller::WebFinger;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json);

sub show ($c) {
    my $resource = $c->param('resource') // '';
    my $domain   = $c->config('domain');
    my $base     = $c->config('scheme') . "://$domain";

    unless ($resource =~ m{\Aacct:([^@]+)\@\Q$domain\E\z}) {
        return $c->render(json => { error => 'not_found' }, status => 404);
    }
    my $username = $1;

    my $exists = $c->pg->db->query(
        'SELECT 1 FROM users WHERE username = ?', $username
    )->array;

    return $c->render(json => { error => 'not_found' }, status => 404)
        unless $exists;

    $c->res->headers->content_type('application/jrd+json');
    $c->render(data => encode_json({
        subject => "acct:$username\@$domain",
        links   => [
            {
                rel  => 'self',
                type => 'application/activity+json',
                href => "$base/users/$username",
            },
        ],
    }));
}

1;
