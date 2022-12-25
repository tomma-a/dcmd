import std.stdio;
import tinyredis.redis;
import tinyredis.subscriber;
import std.format;
import std.string;
import std.algorithm;
import std.array;
import std.concurrency;
import common.util;
import core.stdc.signal;
import core.thread;
import std.getopt;
import std.json;
import vibe.vibe;

__gshared g_done = false;
__gshared CmdMaster master;
__gshared Tid[] client_webs;
//const string REDIS_SUB_ALL="all";
//const string REDIS_MEMBER_KEY="members";
//const string REDIS_RESPONSE_KEY="response";
class CmdMaster
{
public:
    this(string hostname, ushort port = 6379)
    {
        redis = new Redis(hostname, port);
        sub = new Subscriber(hostname, port);
        sub.subscribe(REDIS_RESPONSE_KEY, &handler);
        refresh();
    }

    void clear()
    {
        sub.unsubscribe();
        sub.quit();
        redis.close();
    }

    void refresh()
    {
        auto resp = redis.send(format("SMEMBERS %s", REDIS_MEMBER_KEY));
        if (resp.isArray())
            members = resp.values.map!(r => r.value).array();
    }

    void run()
    {

        while (!g_done)
        {
            sub.processMessages();
            Thread.sleep(dur!("seconds")(1));
        }
        writeln("done");
        clear();
    }

    void runcmd(string line)
    {

        debug writeln("commmandline: ", line);

        if (line.startsWith("/list"))
        {
            refresh();
            JSONValue jj = ["type": "members"];
            jj.object["members"] = JSONValue(members);
            auto msg = jj.toString;
            client_webs.each!((s) => std.concurrency.send(s, msg));
        }
        else if (line.startsWith("/send "))
        {
            auto line_t = line[6 .. $];
            auto index = indexOf(line_t, ' ');
            if (index == -1)
            {
                writeln("Format error for cmd %s", line);
            }
            else
            {
                auto ch = line_t[0 .. index].strip();
                auto msg = line_t[index + 1 .. $].strip();
                send(ch, msg);

            }
        }
        else
        {
            writeln("Unknow command ", line);
        }

    }

    string[] members;
    //private:
    Redis redis;
    Subscriber sub;

    void send(string c, string msg)
    {
        redis.send(format("PUBLISH %s '%s'", c, msg));
    }

    void handler(string ch, string msg)
    {
        writefln("Get %s from channel %s ", msg, ch);
        try
        {

            client_webs.each!((s) => std.concurrency.send(s, msg));

        }
        catch (Exception e)
        {
            writeln(e.msg);
        }
    }

}

private extern (C) void sighandler(int sig) nothrow @system @nogc
{
    g_done = true;

}

private void thread1()
{

    master.run();
    
}
immutable string index;
immutable string semanticjs;
immutable string semanticcss;
immutable string jquery;
shared  static this()
{
    index=import("index.html");
    semanticcss=import("semantic.min.css");
    semanticjs=import("semantic.min.js");
    jquery=import("jquery.min.js");
}
int main(string[] args)
{
    string redishost = "localhost";
    ushort redisport = 6379;
    ushort dport = 8080;
    auto helpInfo = getopt(args, "rhost", "remote redis hostname", &redishost,
            "rport", "remote redis port", &redisport, "listen", "listen port", &dport);
    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Help:", helpInfo.options);
        return 0;
    }
    signal(SIGINT, &sighandler);
    master = new CmdMaster(redishost, redisport);
    auto tid = spawn(&thread1);
    auto settings = new HTTPServerSettings;
    settings.port = dport;
    settings.bindAddresses = ["0.0.0.0"];
    auto router=new URLRouter;
    router.get("/",(req,resp) {resp.contentType="text/html";resp.writeBody(index);});
    router.get("/semantic.min.css",(req,resp) {resp.contentType="text/css";resp.writeBody(semanticcss);});
    router.get("/semantic.min.js",(req,resp) {resp.contentType="text/javascript";resp.writeBody(semanticjs);});
    router.get("/jquery.min.js",(req,resp) { resp.contentType="text/javascript"; resp.writeBody(jquery);});
    router.get("/ws",handleWebSockets(&websockethandler));
    auto listener = listenHTTP(settings, router);
    scope (exit)
    {
        listener.stopListening();
    }

    logInfo(format("Please open http://0.0.0.0:%d/ in your browser.", dport));
    runApplication();
    // m.runcmd();
    return 0;
}

void websockethandler(scope WebSocket socket)
{

    auto tt = runTask({
        while (socket.connected)
        {
            receive((string msg) {
                try
                {
                    socket.send(msg);
                }
                catch (Exception e)
                {
                }
            });
        }
    });
    client_webs ~= tt.tid;
    while (socket.connected && socket.waitForData())
    {
        try
        {
            auto line = socket.receiveText();
            auto args = line.chomp().strip().split(' ');
            if (args.length > 0)
            {

                master.runcmd(line);

            }
        }
        catch (Exception e)
        {
            writeln(e.msg);
            break;
        }

    }
    debug writeln("close a websocket");
    socket.close();
    client_webs = client_webs.remove!((s) => s == tt.tid).array();
    tt.join();
}
