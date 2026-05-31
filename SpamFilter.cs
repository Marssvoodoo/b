using System;
using System.Globalization;
using System.Reflection;
using System.Text.RegularExpressions;

public class CPHInline
{
    // ✅ GUARANTEED BYPASS: add usernames here (case-insensitive)
    private static readonly string[] ALLOWLIST = new string[]
    {
        "blazack1"
    };

    // 🚫 HARDCODED BOT BANLIST: always ban these usernames on sight
    private static readonly string[] BOTBANLIST = new string[]
    {
        "yakkrbot",
        "p_hayden57",
        "6473hdg",
        "sunnday091"
    };

    // Message length thresholds
    private const int LENGTH_SUSPICIOUS  = 200;
    private const int LENGTH_WALL        = 350;
    private const int LENGTH_INSTANT_BAN = 500;

    // Accounts younger than this (in days) are treated as "new" for spam weighting.
    private const int NEW_ACCOUNT_DAYS = 14;

    // ---- Weighted-score ladder (AGGRESSIVE preset) ----
    // Each signal contributes points; the total decides the action. Tune freely.
    //   score >= BAN_THRESHOLD     -> delete + ban
    //   score >= TIMEOUT_THRESHOLD -> delete + timeout
    //   score >= DELETE_THRESHOLD  -> delete only
    //   below DELETE_THRESHOLD     -> allow
    // High-confidence scam combos are worth HARD points so they cross BAN on their own.
    private const int DELETE_THRESHOLD  = 3;
    private const int TIMEOUT_THRESHOLD = 5;
    private const int BAN_THRESHOLD     = 8;
    private const int TIMEOUT_SECONDS   = 600;  // 10-minute timeout
    private const int HARD              = 100;  // points for an instant-ban combo

    public bool Execute()
    {
        string platform = GetArg("platform", "");
        string message  = GetArg("message", GetArg("rawMessage", ""));
        string userName = GetArg("userName", GetArg("user", ""));
        string msgId    = GetArg("msgId", GetArg("messageId", GetArg("targetMessageId", "")));
        string source   = GetArg("eventSource", "");

        // ---- Platform inference (Twitch only) ----
        if (IsBlank(platform))
        {
            if (!IsBlank(source) && source.IndexOf("twitch", StringComparison.OrdinalIgnoreCase) >= 0)
                platform = "twitch";
            else if (!IsBlank(msgId))
                platform = "twitch";
        }

        CPH.LogInfo("[SpamFilter] platform=" + platform
            + " | source=" + source
            + " | user=" + userName
            + " | msgId=" + msgId
            + " | msgLen=" + (message == null ? 0 : message.Length)
            + " | msg=" + (IsBlank(message) ? "(blank)" : (message.Length > 100 ? message.Substring(0, 100) + "..." : message)));

        // Only process Twitch
        if (!platform.Equals("twitch", StringComparison.OrdinalIgnoreCase))
        {
            CPH.LogInfo("[SpamFilter] Non-Twitch platform detected. Ignoring.");
            return true;
        }

        if (IsBlank(message))
            return true;

        if (IsAllowlisted(userName))
        {
            CPH.LogInfo("[SpamFilter] BYPASS allowlist: " + userName);
            return true;
        }

        // 🚫 BOTBANLIST first, before trusted-role bypass
        if (IsBotBanlisted(userName))
        {
            CPH.LogInfo("[SpamFilter] BAN botbanlist: " + userName);
            ExecuteTwitchBan(userName, msgId, "Known spam bot (auto)");
            return true;
        }

        if (IsTrustedRole(platform))
        {
            CPH.LogInfo("[SpamFilter] BYPASS trusted role: " + userName);
            return true;
        }

        string norm = Normalize(message);
        int msgLen  = message.Length;

        CPH.LogInfo("[SpamFilter] norm=" + (norm.Length > 180 ? norm.Substring(0, 180) + "..." : norm));

        // ---- Message length flags ----
        bool isSuspiciousLength = msgLen >= LENGTH_SUSPICIOUS;
        bool isWallOfText       = msgLen >= LENGTH_WALL;
        bool isInstantBanLength = msgLen >= LENGTH_INSTANT_BAN;

        CPH.LogInfo("[SpamFilter] msgLen=" + msgLen
            + " | suspicious=" + isSuspiciousLength
            + " | wall=" + isWallOfText
            + " | instantBan=" + isInstantBanLength);

        // ---- Designer / artwork / overlays spam ----

        bool artServiceWords =
            HasAny(norm,
                "custom artwork", "custom art", "custom gfx", "custom graphics",
                "graphic designer", "gfx designer", "logo design", "logo designer",
                "custom logo", "logos for streamers",
                "overlay", "overlays", "emote", "emotes",
                "banner", "banners", "thumbnail", "thumbnails");

        bool streamerTargeting =
            HasAny(norm, "streamer", "streamers", "your stream", "your channel", "your twitch");

        bool softCTA =
            HasAny(norm,
                "would you like to see", "would u like to see",
                "would you like to check", "would u like to check",
                "want to see", "wanna see", "want to check", "wanna check",
                "like to see it", "like to see them",
                "can show you", "let me show you",
                "check it out", "check them out",
                "see my work", "see some examples", "see some sample", "see some samples");

        bool artworkPitchSoft = artServiceWords && streamerTargeting && softCTA;

        bool artworkPitch =
            HasAny(norm, "custom artwork", "custom art", "custom gfx", "artwork for streamers", "art for streamers") &&
            streamerTargeting && softCTA;

        bool designerCore =
            artworkPitch || artServiceWords ||
            Has(norm, "graphic designer") || Has(norm, "logo design") || Has(norm, "logo designer") ||
            (HasAny(norm, "overlay", "overlays", "emote", "emotes", "banner", "banners", "thumbnail", "thumbnails")
                && HasAny(norm, "design", "designer", "make", "create")) ||
            Has(norm, "commissions open") || Has(norm, "commission open") ||
            (Has(norm, "portfolio") && HasAny(norm, "check", "visit", "link", "see"));

        // ---- Buy-viewers / viewbot spam ----

        bool buyViewersCore =
            Has(norm, "buy viewers") || Has(norm, "buy followers") ||
            Has(norm, "boost your stream") || Has(norm, "promote your channel") ||
            HasAny(norm, "viewbot", "view bot");

        // ---- Contact funnel / links ----

        bool contactFunnel =
            HasAny(norm, "dm me", "message me", "hit me up", "inbox me", "contact me") ||
            HasAny(norm,
                "add me on discord", "add me discord", "add my discord",
                "adding me on discord", "mind adding me on discord", "mind adding me discord",
                "discord", "telegram", "whatsapp", "instagram", "t.me", "wa.me");

        bool hasLink = ContainsLinkish(norm);

        bool viewersPlusLink =
            HasAny(norm, "viewers", "followers") && (hasLink || Has(norm, "remove the space"));

        // ---- Monetization scam ----

        bool monetizationWords =
            HasAny(norm,
                "earn", "earnings", "payout", "revenue", "commission",
                "money", "profit", "income",
                "donate", "donation", "donations", "donors",
                "who might donate", "might donate");

        bool exposureWords =
            HasAny(norm,
                "audience", "community", "exposure", "boost", "growth", "promotion", "promote",
                "grow organically", "organic", "organically",
                "real viewers", "active chat", "active viewers",
                "smaller streamers", "smaller creators",
                "help you grow", "helps streamers grow", "helps creators grow");

        bool newStreamerExploit =
            HasAny(norm,
                "new streamer", "new channel",
                "not yet affiliated", "not affiliated",
                "not yet verified", "not verified",
                "not yet partner", "not partnered");

        bool proposalWords =
            HasAny(norm, "proposal", "offer", "opportunity", "deal", "business proposal", "business deal");

        bool monetizationScam =
            (monetizationWords && (exposureWords || contactFunnel || newStreamerExploit)) ||
            (proposalWords && (monetizationWords || exposureWords) && contactFunnel) ||
            (newStreamerExploit && (monetizationWords || exposureWords || contactFunnel)) ||
            (contactFunnel && HasAny(norm,
                "twitch community", "share your stream", "share your channel", "gain 500", "active audience")) ||
            (isWallOfText && (monetizationWords || exposureWords) && contactFunnel);

        // ---- Discord handle / referral detection ----
        //
        // Two tiers, by design:
        //   * mentionsDiscord            — the word "discord" appears in ANY form
        //                                  (incl. spaced/obfuscated). Treated as a
        //                                  flag worth a closer look, always logged.
        //   * discordHandlePattern /     — a REAL handle is being shared: an @mention
        //     likelyDiscordUsernameNearby  or a token containing a digit/underscore
        //                                  (e.g. "john_doe23", "@coolguy"). Stronger
        //                                  signal, so it can combine with lighter cues.
        //
        // A bare mention on its own does not ban; it only escalates scrutiny by
        // combining with a second scam signal (compliment, support, link, wall, etc.).

        // Bare mention of Discord, including common spacing/obfuscation tricks.
        bool mentionsDiscord =
            HasAny(norm,
                "discord", "discrd", "dicord", "disc0rd", "d1scord", "dis cord",
                "dis-cord", "dischord") ||
            Regex.IsMatch(norm, @"\bd[\W_]*i[\W_]*s[\W_]*c[\W_]*o[\W_]*r[\W_]*d\b") ||
            Regex.IsMatch(norm, @"\b(add|hit|dm|msg|message|find|reach|catch|join)\s+(me|my|the)\s+(on|at|up\s+on)?\s*disc\b");

        if (mentionsDiscord)
            CPH.LogInfo("[SpamFilter] DISCORD mention flagged for review | user=" + userName
                + " | msgLen=" + msgLen);

        // Handle-like token: @name, or a 2-32 char token containing a digit or underscore.
        const string HANDLE = @"(@[a-z0-9_.]{2,32}|[a-z0-9._\-]*[0-9_][a-z0-9._\-]*)";

        bool discordHandlePattern = Regex.IsMatch(
            norm,
            @"\bdiscord\b[\s\W_]{0,40}" + HANDLE + @"\b",
            RegexOptions.IgnoreCase
        );

        bool addOnDiscordReferral =
            Regex.IsMatch(norm,
                @"\b(add|message|contact|hit up)\s+(him|her|them|me)\s+on\s+discord\b",
                RegexOptions.IgnoreCase);

        bool likelyDiscordUsernameNearby = Regex.IsMatch(
            norm,
            @"\bdiscord\b.{0,50}\b" + HANDLE + @"\b",
            RegexOptions.IgnoreCase
        );

        // Any Discord presence — bare mention OR an actual handle — is enough to
        // pull a message into the scam-combo checks below.
        bool discordSignal = mentionsDiscord || discordHandlePattern || likelyDiscordUsernameNearby;

        bool loveBombCompliment =
            HasAny(norm,
                "you have really made my day", "you really made my day", "made my day with your stream",
                "i can't appreciate you enough", "i cant appreciate you enough",
                "i really appreciate you", "i appreciate you so much",
                "i appreciate your stream", "you made my day with your stream", "you made my day");

        bool discordLoveScam =
            discordSignal &&
            (loveBombCompliment || HasAny(norm, "let's reach out", "lets reach out", "reach out on discord"));

        bool tipsOrSquadPattern =
            HasAny(norm,
                "let's squad up", "lets squad up", "squad up soon", "squad up sometime", "squad up",
                "got a few tips", "got some tips", "few tips", "some tips",
                "tips i think you'll find useful", "tips you will find useful", "tips you'll find useful",
                "help you improve", "help you get better");

        bool hitMeUpDiscord =
            HasAny(norm, "hit me up on discord", "hit me up discord", "hit me on discord");

        bool discordTipsScam =
            discordSignal &&
            hitMeUpDiscord && tipsOrSquadPattern;

        bool complimentChannelWords =
            HasAny(norm,
                "been enjoying your channel", "enjoying your channel", "enjoying your stream", "enjoying your content",
                "love your channel", "love your stream", "love your content",
                "your content is seriously good", "your content is really good",
                "your content is so good", "your content is good",
                "great content", "amazing content", "amazing stream",
                "your stream is amazing", "your stream is really amazing",
                "your stream is so amazing", "your stream is great",
                "really amazing", "become your fan", "become your dedicated fan", "dedicated fan",
                "keep it up", "your channel is good", "your channel is great", "your channel is amazing",
                "will like to be a fan", "would like to be a fan", "want to be a fan", "wanna be a fan",
                "be a fan and friend", "be a fan",
                "respect the grind", "dropped a follow", "show real support",
                "i respect your", "respect your grind", "respect your stream",
                "love the grind", "love your grind",
                "show some genuine support", "genuine support",
                "wanted to show some support", "show some support");

        bool supportStayConnectedWords =
            HasAny(norm,
                "i'd love to support you", "id love to support you",
                "support you more", "support you",
                "stay connected", "stay connected with you", "stay in touch", "keep in touch",
                "stay connected more", "connect more", "stay connected.",
                "be a friend", "fan and friend", "friend and fan");

        bool addMeDiscordPhrase =
            HasAny(norm,
                "add me on discord", "add me up on discord", "add me up discord",
                "add me discord", "add my discord", "add me in discord",
                "add me on disc", "add me on ds",
                "adding me on discord", "adding me discord",
                "mind adding me on discord", "mind adding me discord", "mind adding me on disc",
                "add him on discord", "add him on disc",
                "add her on discord", "add her on disc",
                "add them on discord", "add them on disc",
                "you can add him", "you can add her", "you can add them");

        bool discordComplimentSupportScam =
            discordSignal &&
            addMeDiscordPhrase && complimentChannelWords && supportStayConnectedWords;

        bool discordFanSupportScam =
            discordSignal &&
            (addMeDiscordPhrase || ConnectOnDiscordPhrase(norm)) &&
            (complimentChannelWords || supportStayConnectedWords);

        bool playTogetherWords =
            HasAny(norm,
                "let's play together", "lets play together", "play together",
                "let's sometimes play together", "lets sometimes play together",
                "team up", "squad up", "share tips", "share ideas",
                "tips and ideas", "tips & ideas", "tips and", "share tips and ideas");

        bool connectOnDiscord =
            HasAny(norm,
                "let's connect on discord", "lets connect on discord", "connect on discord",
                "let's connect via discord", "lets connect via discord", "connect via discord",
                "let's connect in discord", "lets connect in discord");

        bool discordPlayConnectScam =
            discordSignal &&
            connectOnDiscord && playTogetherWords;

        // ---- NEW: fake fellow-streamer / Discord support scam ----

        bool fakeStreamerDiscordSupport =
            (discordSignal || addMeDiscordPhrase || connectOnDiscord) &&
            HasAny(norm,
                "can't stay long", "cant stay long",
                "i'm at work", "im at work",
                "bring my people", "bring my squad",
                "my people to your next stream",
                "my squad and i will join",
                "my squad will join",
                "once i settle",
                "busy at the moment",
                "fellow streamer",
                "i just follow you",
                "i just followed you",
                "just follow you",
                "just followed you",
                "support each other's", "support each others",
                "support each other's grind", "support each others grind",
                "let's support each other", "lets support each other",
                "connect and make it official",
                "make it official on discord",
                "play cod together",
                "maybe play cod together",
                "let's connect on discord",
                "lets connect on discord",
                "add me on discord");

        // ---- Fake influencer referral / growth service scam ----

        bool bigAccountClaim =
            Regex.IsMatch(norm, @"\b\d{2,}(k|m)\+?\s*(followers|viewers|subs|subscribers)\b") ||
            Regex.IsMatch(norm, @"\b(over\s+)?\d{2,}(k|m)\+?\s*(followers|viewers|subs|subscribers)\b") ||
            Regex.IsMatch(norm, @"\b(hundreds|thousands|millions)\s+of\s+(live\s+)?(viewers|followers|subs|subscribers)\b") ||
            HasAny(norm,
                "top streamer", "top twitch streamer",
                "top twitch",
                "big streamer", "big name", "big channel",
                "famous streamer", "popular streamer",
                "huge following", "massive following",
                "a lot of followers", "millions of followers",
                "thousands of viewers", "thousands of followers",
                "live viewers");

        bool growthPitch =
            HasAny(norm,
                "helps smaller streamers", "help smaller streamers",
                "helps smaller creators", "help smaller creators",
                "genuinely helps smaller creators grow",
                "helps streamers grow", "helps creators grow",
                "help you grow", "grow your channel", "grow organically", "organic growth",
                "real viewers", "active chat", "active viewers", "active audience",
                "loyal supporters", "supporters who subscribe", "supporters who donate",
                "might donate", "who might donate", "who subscribe", "who gift", "who donate",
                "subscribe, gift", "subscribe and gift", "gift and donate",
                "subscribe gift and donate", "subscribe, gift, and donate");

        bool referralCloser =
            HasAny(norm,
                "tell him", "tell her", "tell them",
                "let him know", "let her know", "let them know",
                "sent you", "referred you",
                "mention my name", "say i sent", "say i referred",
                "approach respectfully",
                "he's a big name", "she's a big name", "big name",
                "boost your journey", "boost your stream journey",
                "taking this step");

        bool influencerReferralScam =
            (discordSignal || addOnDiscordReferral) &&
            bigAccountClaim &&
            (growthPitch || referralCloser);

        bool directGrowthReferralScam =
            HasAny(norm,
                "top twitch streamer",
                "helps smaller creators grow", "helps smaller streamers grow",
                "real viewers", "active chat", "loyal supporters") &&
            HasAny(norm,
                "add him on discord", "add her on discord", "add them on discord",
                "let him know", "let her know", "let them know",
                "sent you", "referred you", "taking this step");

        CPH.LogInfo("[SpamFilter] bigAccountClaim=" + bigAccountClaim
            + " | growthPitch=" + growthPitch
            + " | referralCloser=" + referralCloser
            + " | mentionsDiscord=" + mentionsDiscord
            + " | discordSignal=" + discordSignal
            + " | discordHandlePattern=" + discordHandlePattern
            + " | addOnDiscordReferral=" + addOnDiscordReferral
            + " | likelyDiscordUsernameNearby=" + likelyDiscordUsernameNearby
            + " | influencerReferralScam=" + influencerReferralScam
            + " | directGrowthReferralScam=" + directGrowthReferralScam
            + " | fakeStreamerDiscordSupport=" + fakeStreamerDiscordSupport);

        // ---- Stream promo / social bot spam ----

        bool streamPromoContext =
            HasAny(norm, "socials", "commands", "follow us", "twitter", "tiktok", "youtube", "instagram") ||
            Regex.IsMatch(norm, @"!\w+");

        bool streamPromoBot =
            Has(norm, "checking out the socials") ||
            (Has(norm, "support this stream") && streamPromoContext) ||
            (Has(norm, "support the stream") && streamPromoContext) ||
            (Has(norm, "check out the socials") && streamPromoContext) ||
            (Has(norm, "using the following commands") && streamPromoContext) ||
            (Has(norm, "use the following commands") && streamPromoContext) ||
            (Has(norm, "following commands") && HasAny(norm, "socials", "stream", "support"));

        // ---- Identity-bait live self-promo spam ----

        bool selfPromoLive =
            HasAny(norm,
                "im live", "i'm live", "i am live",
                "live right now", "streaming right now",
                "come watch me", "come watch my stream",
                "check out my stream", "check out my channel",
                "follow me", "watch me live",
                "just went live", "just started streaming") ||
            Regex.IsMatch(norm, @"#\w+");

        bool identityBait =
            HasAny(norm,
                "trans streamer", "trans stream", "lgbt streamer", "lgbtq streamer",
                "gay streamer", "queer streamer", "another trans", "fellow trans",
                "fellow streamer", "another streamer", "you pass",
                "its wholesome", "it's wholesome", "so wholesome",
                "so cool to see", "cool to see another", "love to see another",
                "love seeing another", "great to see another", "nice to see another");

        bool identityBaitLivePromo = identityBait && selfPromoLive;

        // ---- New-account / first-message weighting ----
        //
        // A user's first-ever message, or a message from a very new account, is the
        // single strongest spam tell. Twitch passes the first-message flag directly.
        // Account age is read from args if a preceding "Get User Info" sub-action set
        // them; otherwise it is looked up via the Twitch API (best-effort, reflection-
        // based so it compiles on any Streamer.bot version and never throws fatally).

        bool isFirstMessage =
            GetArgBool("isFirstMessage") || GetArgBool("firstMessage") ||
            GetArgBool("firstTimeChatter") || GetArgBool("isFirstChat");

        string userId = GetArg("userId", GetArg("userid", GetArg("userID", "")));
        double accountAgeDays = GetAccountAgeDays(userId, userName);

        bool isNewAccount = accountAgeDays >= 0 && accountAgeDays <= NEW_ACCOUNT_DAYS;
        bool newOrFirst   = isFirstMessage || isNewAccount;

        // Signals that are individually too weak to ban on, but are damning when they
        // arrive in a user's first message or from a brand-new account.
        bool lightSpamSignal =
            hasLink || discordSignal || contactFunnel ||
            bigAccountClaim || artServiceWords ||
            (monetizationWords && exposureWords);

        bool newAccountSpam = newOrFirst && lightSpamSignal;

        CPH.LogInfo("[SpamFilter] firstMessage=" + isFirstMessage
            + " | accountAgeDays=" + (accountAgeDays < 0 ? "unknown" : accountAgeDays.ToString("0"))
            + " | isNewAccount=" + isNewAccount
            + " | lightSpamSignal=" + lightSpamSignal
            + " | newAccountSpam=" + newAccountSpam);

        // ---- Weighted scoring ----
        //
        // Every signal adds points. High-confidence scam combos are worth HARD points
        // so they alone cross the ban threshold; weaker signals accumulate so several
        // mild cues together still escalate. The total maps to delete / timeout / ban.

        System.Text.StringBuilder sb = new System.Text.StringBuilder();
        int score = 0;

        // High-confidence combos -> effectively instant ban
        score += AddSig(sb, isInstantBanLength,                      HARD, "instantLen");
        score += AddSig(sb, buyViewersCore,                          HARD, "buyViewers");
        score += AddSig(sb, monetizationScam,                        HARD, "monetizationScam");
        score += AddSig(sb, artworkPitchSoft,                        HARD, "artworkPitchSoft");
        score += AddSig(sb, designerCore && (contactFunnel || hasLink), HARD, "designerContact");
        score += AddSig(sb, viewersPlusLink,                         HARD, "viewersPlusLink");
        score += AddSig(sb, discordLoveScam,                         HARD, "discordLove");
        score += AddSig(sb, discordTipsScam,                         HARD, "discordTips");
        score += AddSig(sb, discordComplimentSupportScam,            HARD, "discordComplimentSupport");
        score += AddSig(sb, discordFanSupportScam,                   HARD, "discordFanSupport");
        score += AddSig(sb, discordPlayConnectScam,                  HARD, "discordPlayConnect");
        score += AddSig(sb, fakeStreamerDiscordSupport,              HARD, "fakeStreamerDiscord");
        score += AddSig(sb, streamPromoBot,                          HARD, "streamPromoBot");
        score += AddSig(sb, identityBaitLivePromo,                   HARD, "identityBaitLive");
        score += AddSig(sb, influencerReferralScam,                  HARD, "influencerReferral");
        score += AddSig(sb, directGrowthReferralScam,                HARD, "directGrowthReferral");
        score += AddSig(sb, newAccountSpam,                          HARD, "newAccountSpam");

        // Weak / medium signals that accumulate
        score += AddSig(sb, hasLink,                                 3, "link");
        score += AddSig(sb, discordSignal,                           2, "discord");
        score += AddSig(sb, discordHandlePattern || likelyDiscordUsernameNearby, 2, "discordHandle");
        score += AddSig(sb, contactFunnel,                           3, "contactFunnel");
        score += AddSig(sb, bigAccountClaim,                         3, "bigAccount");
        score += AddSig(sb, monetizationWords,                       2, "monetizationWords");
        score += AddSig(sb, exposureWords,                           2, "exposureWords");
        score += AddSig(sb, streamerTargeting,                       1, "streamerTargeting");
        score += AddSig(sb, newStreamerExploit,                      2, "newStreamerExploit");
        score += AddSig(sb, proposalWords,                           1, "proposal");
        score += AddSig(sb, artServiceWords,                         3, "artService");
        score += AddSig(sb, selfPromoLive,                           3, "selfPromoLive");
        score += AddSig(sb, identityBait,                            2, "identityBait");
        score += AddSig(sb, growthPitch,                             2, "growthPitch");
        score += AddSig(sb, referralCloser,                          2, "referralCloser");
        score += AddSig(sb, loveBombCompliment,                      2, "loveBomb");
        score += AddSig(sb, complimentChannelWords,                  1, "complimentChannel");
        score += AddSig(sb, supportStayConnectedWords,               1, "supportConnected");
        score += AddSig(sb, addMeDiscordPhrase,                      3, "addMeDiscord");
        score += AddSig(sb, hitMeUpDiscord,                          2, "hitMeUpDiscord");
        score += AddSig(sb, tipsOrSquadPattern,                      1, "tipsSquad");
        score += AddSig(sb, playTogetherWords,                       1, "playTogether");
        score += AddSig(sb, connectOnDiscord,                        2, "connectDiscord");
        score += AddSig(sb, isSuspiciousLength,                      1, "suspLen");
        score += AddSig(sb, isWallOfText,                            2, "wall");
        score += AddSig(sb, newOrFirst,                              2, "newOrFirst");

        // ---- Map score to an action ----
        int action = 0;            // 0 allow, 1 delete, 2 timeout, 3 ban
        string actionName = "allow";
        if (score >= BAN_THRESHOLD)          { action = 3; actionName = "BAN"; }
        else if (score >= TIMEOUT_THRESHOLD) { action = 2; actionName = "TIMEOUT"; }
        else if (score >= DELETE_THRESHOLD)  { action = 1; actionName = "DELETE"; }

        CPH.LogInfo("[SpamFilter] score=" + score + " | action=" + actionName
            + " | thresholds d/t/b=" + DELETE_THRESHOLD + "/" + TIMEOUT_THRESHOLD + "/" + BAN_THRESHOLD
            + " | signals: " + sb.ToString());

        if (action == 0)
            return true;

        string reason = "Spam detected (auto, score " + score + ")";

        // Delete-only, or no username to act on -> just remove the message.
        if (action == 1 || IsBlank(userName))
        {
            bool deleted = TryDeleteMessage(msgId);
            CPH.LogInfo("[SpamFilter] " + (action == 1 ? "DELETE" : actionName + " wanted but username blank; delete-only")
                + " | user=" + userName + " | deleted=" + deleted + " | msgId=" + msgId);
            return true;
        }

        if (action == 2)
        {
            CPH.LogInfo("[SpamFilter] TIMEOUT " + userName + " (" + TIMEOUT_SECONDS + "s)");
            ExecuteTwitchTimeout(userName, msgId, TIMEOUT_SECONDS, reason);
        }
        else
        {
            CPH.LogInfo("[SpamFilter] BANNING " + userName);
            ExecuteTwitchBan(userName, msgId, reason);
        }

        return true;
    }

    // Adds points to the running total and records the signal name when present.
    private int AddSig(System.Text.StringBuilder sb, bool cond, int pts, string name)
    {
        if (!cond) return 0;
        sb.Append(name).Append("(+").Append(pts).Append(") ");
        return pts;
    }

    // --------- Twitch action executors ---------

    private bool TryDeleteMessage(string msgId)
    {
        try
        {
            if (!IsBlank(msgId))
                return CPH.TwitchDeleteChatMessage(msgId, false);
        }
        catch (Exception ex)
        {
            CPH.LogInfo("[SpamFilter] Twitch delete error: " + ex.Message);
        }

        return false;
    }

    private void ExecuteTwitchTimeout(string userName, string msgId, int seconds, string reason)
    {
        bool deleted   = TryDeleteMessage(msgId);
        bool timedOut  = InvokeTimeout(userName, seconds, reason);

        CPH.LogInfo("[SpamFilter] timeout=" + timedOut
            + " | seconds=" + seconds
            + " | delete=" + deleted
            + " | user=" + userName
            + " | msgId=" + msgId
            + " | reason=" + reason);
    }

    // Timeout via reflection so it compiles regardless of which TwitchTimeoutUser
    // overload this Streamer.bot version exposes; falls back through shorter signatures.
    private bool InvokeTimeout(string userName, int seconds, string reason)
    {
        try
        {
            Type ct = CPH.GetType();

            MethodInfo m = ct.GetMethod("TwitchTimeoutUser",
                new Type[] { typeof(string), typeof(int), typeof(string), typeof(bool) });
            if (m != null)
                return ToBool(m.Invoke(CPH, new object[] { userName, seconds, reason, false }));

            m = ct.GetMethod("TwitchTimeoutUser",
                new Type[] { typeof(string), typeof(int), typeof(string) });
            if (m != null)
                return ToBool(m.Invoke(CPH, new object[] { userName, seconds, reason }));

            m = ct.GetMethod("TwitchTimeoutUser",
                new Type[] { typeof(string), typeof(int) });
            if (m != null)
                return ToBool(m.Invoke(CPH, new object[] { userName, seconds }));

            CPH.LogInfo("[SpamFilter] TwitchTimeoutUser not found; cannot timeout " + userName);
        }
        catch (Exception ex)
        {
            CPH.LogInfo("[SpamFilter] Twitch timeout error: " + ex.Message);
        }

        return false;
    }

    private bool ToBool(object o)
    {
        return o is bool ? (bool)o : true;
    }

    private void ExecuteTwitchBan(string userName, string msgId, string reason)
    {
        bool deleted = TryDeleteMessage(msgId);
        bool banned  = false;

        try
        {
            banned = CPH.TwitchBanUser(userName, reason, false);
        }
        catch (Exception ex)
        {
            CPH.LogInfo("[SpamFilter] Twitch ban error: " + ex.Message);
        }

        CPH.LogInfo("[SpamFilter] delete=" + deleted
            + " | ban=" + banned
            + " | user=" + userName
            + " | msgId=" + msgId
            + " | reason=" + reason);
    }

    // --------- Bypass / banlist logic ---------

    private bool IsAllowlisted(string userName)
    {
        if (IsBlank(userName)) return false;

        string u = userName.Trim().TrimStart('@').Replace(" ", "");
        for (int i = 0; i < ALLOWLIST.Length; i++)
        {
            if (ALLOWLIST[i] != null &&
                u.Equals(ALLOWLIST[i].Trim().TrimStart('@').Replace(" ", ""), StringComparison.OrdinalIgnoreCase))
                return true;
        }

        return false;
    }

    private bool IsBotBanlisted(string userName)
    {
        if (IsBlank(userName)) return false;

        string u = userName.Trim().TrimStart('@').Replace(" ", "");
        for (int i = 0; i < BOTBANLIST.Length; i++)
        {
            if (BOTBANLIST[i] != null &&
                u.Equals(BOTBANLIST[i].Trim().TrimStart('@').Replace(" ", ""), StringComparison.OrdinalIgnoreCase))
                return true;
        }

        return false;
    }

    private bool IsTrustedRole(string platform)
    {
        if (platform.Equals("twitch", StringComparison.OrdinalIgnoreCase))
        {
            bool isBroadcaster = GetArgBool("isBroadcaster") || GetArgBool("broadcaster");
            bool isMod         = GetArgBool("isModerator") || GetArgBool("isMod") || GetArgBool("moderator");
            bool isVip         = GetArgBool("isVip") || GetArgBool("vip");

            string badges = GetArg("badges", GetArg("userBadges", ""));
            if (!IsBlank(badges))
            {
                string b = badges.ToLowerInvariant();

                if (Regex.IsMatch(b, @"(^|[,\s;|])broadcaster([,\s;|]|$)"))
                    isBroadcaster = true;

                if (Regex.IsMatch(b, @"(^|[,\s;|])moderator([,\s;|]|$)"))
                    isMod = true;

                if (Regex.IsMatch(b, @"(^|[,\s;|])vip([,\s;|]|$)"))
                    isVip = true;
            }

            CPH.LogInfo("[SpamFilter] trustedCheck twitch"
                + " | broadcaster=" + isBroadcaster
                + " | mod=" + isMod
                + " | vip=" + isVip
                + " | badges=" + badges);

            return isBroadcaster || isMod || isVip;
        }

        return false;
    }

    // --------- Helpers ---------

    private bool IsBlank(string s)
    {
        return string.IsNullOrWhiteSpace(s);
    }

    private string GetArg(string key, string fallback)
    {
        try
        {
            object val;
            if (CPH.TryGetArg(key, out val) && val != null)
                return val.ToString();
        }
        catch { }

        return fallback;
    }

    private bool GetArgBool(string key)
    {
        try
        {
            object val;
            if (CPH.TryGetArg(key, out val) && val != null)
            {
                if (val is bool)
                    return (bool)val;

                string s = val.ToString().Trim().ToLowerInvariant();
                return (s == "true" || s == "1" || s == "yes");
            }
        }
        catch { }

        return false;
    }

    // Returns the account age in days, or -1 if it cannot be determined.
    private double GetAccountAgeDays(string userId, string userLogin)
    {
        // 1) Explicit args (e.g. set by a preceding "Get User Info" sub-action).
        double argAge = ParseDouble(GetArg("accountAgeDays", GetArg("accountAge", "")));
        if (argAge >= 0) return argAge;

        DateTime created;
        if (TryParseDate(GetArg("accountCreated", GetArg("createdAt", GetArg("targetCreatedAt", ""))), out created))
            return (DateTime.UtcNow - created.ToUniversalTime()).TotalDays;

        // 2) Best-effort API lookup via reflection. This never references a method or
        //    return type that might be missing in this Streamer.bot version, so the
        //    script always compiles; if the call isn't available it simply returns -1.
        try
        {
            object info = InvokeCph("TwitchGetExtendedUserInfoById", userId)
                       ?? InvokeCph("TwitchGetExtendedUserInfoByLogin", userLogin);

            if (info != null)
            {
                DateTime? c = ReadDateProperty(info,
                    "Created", "AccountCreated", "CreatedAt", "AccountCreatedAt",
                    "UserCreated", "CreatedAtRfc3339");
                if (c.HasValue)
                    return (DateTime.UtcNow - c.Value.ToUniversalTime()).TotalDays;
            }
        }
        catch (Exception ex)
        {
            CPH.LogInfo("[SpamFilter] account-age lookup skipped: " + ex.Message);
        }

        return -1; // unknown -> account-age weighting stays inactive
    }

    private object InvokeCph(string method, string arg)
    {
        if (IsBlank(arg)) return null;
        try
        {
            MethodInfo m = CPH.GetType().GetMethod(method, new Type[] { typeof(string) });
            if (m == null) return null;
            return m.Invoke(CPH, new object[] { arg });
        }
        catch
        {
            return null;
        }
    }

    private DateTime? ReadDateProperty(object obj, params string[] names)
    {
        Type t = obj.GetType();
        for (int i = 0; i < names.Length; i++)
        {
            PropertyInfo p = t.GetProperty(names[i]);
            if (p == null) continue;

            object v = p.GetValue(obj, null);
            if (v == null) continue;

            if (v is DateTime) return (DateTime)v;
            if (v is DateTimeOffset) return ((DateTimeOffset)v).UtcDateTime;

            DateTime parsed;
            if (TryParseDate(v.ToString(), out parsed)) return parsed;
        }

        return null;
    }

    private bool TryParseDate(string s, out DateTime dt)
    {
        dt = default(DateTime);
        if (IsBlank(s)) return false;

        return DateTime.TryParse(s, CultureInfo.InvariantCulture,
            DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out dt);
    }

    private double ParseDouble(string s)
    {
        double d;
        if (!IsBlank(s) && double.TryParse(s, NumberStyles.Any, CultureInfo.InvariantCulture, out d))
            return d;

        return -1;
    }

    private bool Has(string hay, string needle)
    {
        return hay.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0;
    }

    private bool HasAny(string hay, params string[] needles)
    {
        for (int i = 0; i < needles.Length; i++)
        {
            if (Has(hay, needles[i]))
                return true;
        }

        return false;
    }

    private bool ConnectOnDiscordPhrase(string norm)
    {
        return HasAny(norm,
            "let's connect on discord", "lets connect on discord", "connect on discord",
            "let's connect via discord", "lets connect via discord", "connect via discord",
            "let's connect in discord", "lets connect in discord");
    }

    private string Normalize(string s)
    {
        string t = (s ?? "").ToLowerInvariant().Normalize(System.Text.NormalizationForm.FormKC);

        // Strip zero-width / invisible chars
        t = Regex.Replace(t, @"[\u200B-\u200F\uFEFF]", "");

        // Strip all surrogate-pair emoji
        t = Regex.Replace(t, @"[\uD800-\uDFFF]", "");

        // Strip common single-codepoint emoji/arrows below U+FFFF
        t = Regex.Replace(t, @"[\u2600-\u27FF\u2B00-\u2BFF\uFE00-\uFE0F]", "");

        // Replace leftover weird symbols/punctuation with spaces, keep useful URL/handle chars
        t = Regex.Replace(t, @"[^\w\s\.\-:@/]", " ");

        // Normalize "dot com" variants
        t = Regex.Replace(t, @"\b(d\s*o\s*t)\b", "dot");
        t = Regex.Replace(t, @"\bdot\s+(com|net|org|gg|io|tv|co|link|shop)\b", ".$1");
        t = Regex.Replace(t, @"\s*\.\s*(com|net|org|gg|io|tv|co|link|shop)\b", ".$1");

        // hxxp obfuscation
        t = t.Replace("hxxp://", "http://").Replace("hxxps://", "https://");

        // Collapse repeated letters
        t = Regex.Replace(t, @"([a-z])\1{2,}", "$1$1");

        // Collapse whitespace
        t = Regex.Replace(t, @"\s+", " ").Trim();

        return t;
    }

    private bool ContainsLinkish(string t)
    {
        if (IsBlank(t)) return false;

        if (t.Contains("http://") || t.Contains("https://") || t.Contains("www."))
            return true;

        if (Regex.IsMatch(t, @"\.(com|net|org|gg|io|tv|co|link|shop)\b"))
            return true;

        if (Regex.IsMatch(t, @"\b(bit\.ly|tinyurl\.com|t\.co|cutt\.ly)\b"))
            return true;

        return false;
    }
}
