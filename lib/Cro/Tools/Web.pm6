use Cro::HTTP::Router::WebSocket;
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::Tools::Link::Editor;
use Cro::Tools::Runner;
use Cro::Tools::Template;
use Cro::Tools::TemplateLocator;
use JSON::Fast;

sub web(Str $host, Int $port, $runner) is export {
    my $stub-events = Supplier.new;
    my $logs-events = Supplier.new;
    sub send-event($channel, %content) {
        my $msg = { WS_ACTION => True,
                    action => %content };
        given $channel {
            when 'stub' {
                $stub-events.emit: $msg;
            }
            when 'logs' {
                $logs-events.emit: $msg;
            }
        }
    }

    my $application = route {
        get -> {
            content 'text/html', %?RESOURCES<web/index.html>.slurp;
        }
        post -> 'service' {
            request-body -> %json {
                my @commands = <start restart stop
                              trace-on trace-off
                              trace-all-on trace-all-off>;
                unless %json<action> ⊆ @commands {
                    bad-request;
                }
                content 'text/html', '';
                start {
                    $runner.start(%json<id>)        if %json<action> eq 'start';
                    $runner.stop(%json<id>)         if %json<action> eq 'stop';
                    $runner.restart(%json<id>)      if %json<action> eq 'restart';
                    $runner.trace(%json<id>, 'on')  if %json<action> eq 'trace-on';
                    $runner.trace(%json<id>, 'off') if %json<action> eq 'trace-off';
                    $runner.trace-all('on')         if %json<action> eq 'trace-all-on';
                    $runner.trace-all('off')        if %json<action> eq 'trace-all-off';
                }
            }
        }
        post -> 'stub' {
            request-body -> %json {
                content 'text/html', '';
                start {
                    my @templates = get-available-templates(Cro::Tools::Template);
                    my $found = @templates.first(*.id eq %json<type>);
                    my %options = %json<options>>>.Hash;
                    my ($generated-links, @links);
                    if $found.get-option-errors(%options) -> @errors {
                        send-event('stub', { type => 'STUB_OPTIONS_ERROR_OCCURED',
                                             errors => @errors });
                    }
                    else {
                        my $where = $*CWD.add(%json<id>);
                        mkdir $where;
                        $found.generate($where, %json<id>, %json<id>, %options, $generated-links, @links);
                        send-event('stub', { type => 'STUB_STUBBED' });
                        CATCH {
                            default {
                                my @errors = .backtrace.full.split("\n");
                                send-event('stub', { type => 'STUB_STUB_ERROR_OCCURED',
                                                     :@errors });
                            }
                        }
                    }
                }
            }
        }
        get -> 'overview-road' {
            web-socket -> $incoming {
                supply {
                    my @elements;
                    my %services = links-graph();
                    for %services<outer>.flat -> $cro-file {
                        @elements.push: { data => { id => $cro-file.id } };
                        for $cro-file.links {
                            @elements.push: { data => { id => .endpoint,
                                                        source => $cro-file.id,
                                                        target => .service
                                                      }
                                            }
                        }
                    }
                    emit to-json {
                        WS_ACTION => True,
                        action => {
                            type => 'OVERVIEW_GRAPH',
                            graph => @elements
                        }
                    };
                }
            }
        }
        get -> 'logs-road' {
            web-socket -> $incoming {
                supply {
                    whenever $logs-events.Supply {
                        emit to-json $_;
                    }
                }
            }
        }
        get -> 'stub-road' {
            web-socket -> $incoming {
                my @templates = get-available-templates(Cro::Tools::Template);
                supply {
                    whenever $stub-events.Supply {
                        emit to-json $_;
                    }
                    my @result = ();
                    for @templates -> $_ {
                        my %result;
                        %result<id> = .id;
                        %result<name> = .name;
                        my @options;
                        @options.push((.id, .name,
                                       .type.^name,
                                       # We don't send blocks (yet?)
                                       .default ~~ Bool ?? .default !! False).List) for .options;
                        %result<options> = @options;
                        @result.push(%result);
                    }
                    emit to-json {
                        WS_ACTION => True,
                        action => {
                            type => 'STUB_TEMPLATES',
                            templates => @result
                        }
                    };
                }
            }
        }
        get -> 'services-road' {
            web-socket -> $incoming {
                supply whenever $runner.run() -> $_ {
                    sub emit-action($_, $type) {
                        my %action = :$type, id => .cro-file.id,
                                     name => .cro-file.name,
                                     tracing => .tracing;
                        emit to-json { WS_ACTION => True, :%action }
                    }

                    when Cro::Tools::Runner::Started {
                        emit-action($_, 'SERVICE_STARTED');
                        my %event = type => 'LOGS_NEW_CHANNEL', id => .cro-file.id;
                        send-event('logs', %event);
                    }
                    when Cro::Tools::Runner::Restarted {
                        emit-action($_, 'SERVICE_RESTARTED')
                    }
                    when Cro::Tools::Runner::Stopped {
                        emit-action($_, 'SERVICE_STOPPED')
                    }
                    when Cro::Tools::Runner::UnableToStart {
                        emit-action($_, 'SERVICE_UNABLE_TO_START')
                    }
                    when Cro::Tools::Runner::Output {
                        my %event = type => 'LOGS_UPDATE_CHANNEL',
                                    id => .service-id, payload => .line;
                        send-event('logs', %event);
                    }
                    when Cro::Tools::Runner::Trace {
                        my %event = type => 'LOGS_UPDATE_CHANNEL',
                                    id => .service-id, payload => .line;
                        send-event('logs', %event);
                    }
                }
            }
        }
        get -> 'css', *@path {
            with %?RESOURCES{('web', 'css', |@path).join('/')} {
                content 'text/css', .slurp;
            }
            else {
                not-found;
            }
        }
        get -> 'js', *@path {
            with %?RESOURCES{('web', 'js', |@path).join('/')} {
                content 'text/javascript', .slurp;
            }
            else {
                not-found;
            }
        }
        get -> 'fonts', *@path {
            with %?RESOURCES{('web', 'fonts', |@path).join('/')} {
                content 'font/woff2', .slurp :bin;
            }
            else {
                not-found;
            }
        }
    }
    given Cro::HTTP::Server.new(:$host, :$port, :$application) {
        .start;
        .return;
    }
}
