package FediVid::Controller::SPA;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::File qw(path);

sub index ($c) {
    my $dist = $c->app->home->rel_file('frontend/dist');
    my $index = path($dist, 'index.html');

    unless (-f $index) {
        return $c->render(text => 'Frontend not built. Run: cd frontend && npm run build', status => 503);
    }

    $c->reply->static('index.html');
}

sub asset ($c) {
    my $path = $c->param('path') // '';
    return $c->reply->static('index.html') unless length $path;

    my $dist = $c->app->home->rel_file('frontend/dist');
    my $full = path($dist, $path);

    # Block traversal
    my $canonical = $full->to_string;
    return $c->reply->static('index.html') if $canonical =~ /\.\./;

    return $c->reply->static("frontend/dist/$path");
}

1;
