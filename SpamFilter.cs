using System;
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

        // Wall-of-text + a real Discord handle (not just the word "discord").
        bool discordWallOfText =
            discordSignal && isWallOfText;

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

        // ---- Combine into shouldBan ----

        bool shouldBan =
            // Instant ban
            isInstantBanLength ||

            // Standard pattern detections
            buyViewersCore ||
            fakeStreamerDiscordSupport ||
            (designerCore && (contactFunnel || hasLink)) ||
            artworkPitchSoft ||
            viewersPlusLink ||
            monetizationScam ||
            discordLoveScam ||
            discordTipsScam ||
            discordComplimentSupportScam ||
            discordFanSupportScam ||
            discordWallOfText ||
            discordPlayConnectScam ||
            streamPromoBot ||
            identityBaitLivePromo ||
            influencerReferralScam ||
            directGrowthReferralScam ||

            // Wall-of-text + signal
            (isWallOfText && contactFunnel) ||
            (isWallOfText && hasLink) ||
            (isWallOfText && bigAccountClaim) ||
            (isWallOfText && monetizationWords) ||
            (isWallOfText && exposureWords && streamerTargeting) ||

            // Suspicious length + layered weak signals
            (isSuspiciousLength && bigAccountClaim && (growthPitch || addOnDiscordReferral)) ||
            (isSuspiciousLength && discordSignal && referralCloser);

        CPH.LogInfo("[SpamFilter] shouldBan=" + shouldBan
            + " | instantBanLen=" + isInstantBanLength
            + " | wall=" + isWallOfText
            + " | discordWall=" + discordWallOfText
            + " | monetizationScam=" + monetizationScam
            + " | discordFanSupport=" + discordFanSupportScam
            + " | influencerReferral=" + influencerReferralScam
            + " | directGrowthReferral=" + directGrowthReferralScam
            + " | fakeStreamerDiscordSupport=" + fakeStreamerDiscordSupport);

        if (!shouldBan)
            return true;

        // Delete message even if username is blank
        if (IsBlank(userName))
        {
            bool deletedNoUser = false;

            try
            {
                if (!IsBlank(msgId))
                    deletedNoUser = CPH.TwitchDeleteChatMessage(msgId, false);
            }
            catch (Exception ex)
            {
                CPH.LogInfo("[SpamFilter] Twitch delete error (blank user): " + ex.Message);
            }

            CPH.LogInfo("[SpamFilter] Deleted spam message with blank username | deleted=" + deletedNoUser + " | msgId=" + msgId);
            return true;
        }

        CPH.LogInfo("[SpamFilter] BANNING " + userName);
        ExecuteTwitchBan(userName, msgId, "Spam detected (auto)");

        return true;
    }

    // --------- Twitch ban executor ---------

    private void ExecuteTwitchBan(string userName, string msgId, string reason)
    {
        bool deleted = false;
        bool banned  = false;

        try
        {
            if (!IsBlank(msgId))
                deleted = CPH.TwitchDeleteChatMessage(msgId, false);
        }
        catch (Exception ex)
        {
            CPH.LogInfo("[SpamFilter] Twitch delete error: " + ex.Message);
        }

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
        t = Regex.Replace(t, @"[​-‏﻿]", "");

        // Strip all surrogate-pair emoji
        t = Regex.Replace(t, @"[\uD800-\uDFFF]", "");

        // Strip common single-codepoint emoji/arrows below U+FFFF
        t = Regex.Replace(t, @"[☀-⟿⬀-⯿︀-️]", "");

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
