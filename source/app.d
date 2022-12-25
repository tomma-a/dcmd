//Modified by: 1100110
import std.stdio;
import tinyredis.redis;
import tinyredis.subscriber;
import std.format;
import std.string;
import std.process;
import std.array;
import std.concurrency;
import common.util;
import core.stdc.signal;
import std.json;
import std.getopt;
import core.thread;

__gshared g_done = false;
class CmdAgent
{
public:
    this(string hostname, ushort port = 6379)
    {
        redis = new Redis(hostname, port);
        sub = new Subscriber(hostname, port);
        this.hostname = gethostname();
        redis.send(format("SADD %s  %s", REDIS_MEMBER_KEY, hostname));
        sub.subscribe(REDIS_SUB_ALL, &handler);
        sub.psubscribe(hostname ~ "*", &phandler);
    }

    void clear()
    {
        sub.unsubscribe();
        sub.punsubscribe();
        sub.quit();
        redis.send(format("SREM %s  %s", REDIS_MEMBER_KEY, hostname));
        redis.close();
    }

    void run()
    {
        while (!g_done)
        {
            sub.processMessages();
            Thread.sleep(dur!("seconds")(1));
        }
        clear();
    }

private:
    Redis redis;
    string hostname;
    Subscriber sub;
    string gethostname()
    {
        auto pp = std.process.execute(["hostname"]);
        if (pp.status != 0)
            return "";
        return pp.output.chomp();
    }

    void send(string r)
    {
        JSONValue jj = ["hostname": hostname, "result": r, "type": "execute"];
        redis.send(format("PUBLISH %s '%s'", REDIS_RESPONSE_KEY, jj.toString()));
    }

    void handler(string ch, string msg)
    {
        debug writefln("Get %s from channel %s", msg, ch);
        auto result = execute(msg);
        debug writeln("execute result", result);
        if (result.length > 0)
            send(result);
    }

    void phandler(string pattern, string ch, string msg)
    {
        debug writefln("PGet %s from channel %s with pattern: %s", msg, ch, pattern);
        auto result = execute(msg);

        if (result.length > 0)
            send(result);
    }

    string execute(string line)
    {
        auto args = line.split(' ');
        if (args.length < 1)
            return "";
        try
        {
            auto pp = std.process.execute(args);
            return pp.output;
        }
        catch (Exception e)
        {
            writeln("Exception happened: ", e.msg);
            return "";
        }
    }
}

extern (C) void sighandler(int sig) nothrow @system @nogc
{
    g_done = true;
}

int main(string[] args)
{
    string redishost = "localhost";
    ushort redisport = 6379;
    auto helpInfo = getopt(args, "rhost", "remote redis hostname", &redishost,
            "rport", "remote redis port", &redisport);
    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Help:", helpInfo.options);
        return 0;
    }
    signal(SIGINT, &sighandler);
    CmdAgent a = new CmdAgent(redishost, redisport);
    a.run();

    return 0;
}
