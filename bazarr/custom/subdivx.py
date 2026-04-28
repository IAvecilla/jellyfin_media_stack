# -*- coding: utf-8 -*-

from __future__ import absolute_import

import logging
import re
import time
from requests import Session
from requests.exceptions import JSONDecodeError
from subliminal import ProviderError
from subliminal.video import Episode, Movie
from subliminal_patch.exceptions import APIThrottled
from subliminal_patch.providers import Provider
from subliminal_patch.providers.utils import (
    get_archive_from_bytes,
    get_subtitle_from_archive,
    update_matches,
)
from subliminal_patch.subtitle import Subtitle
from subzero.language import Language

logger = logging.getLogger(__name__)

_SUBX_BASE_URL = "https://subx-api.duckdns.org"

# ---------------------------
# Helpers
# ---------------------------

def _series_sanitizer(title):
    title = title or ""
    title = re.sub(r"\[._\]+", " ", title)
    title = re.sub(r"\s+", " ", title).strip()
    return title

def _unique_nonempty(seq):
    seen = set()
    out = []
    for x in seq:
        if not x:
            continue
        if x not in seen:
            seen.add(x)
            out.append(x)
    return out

def _collect_titles(video, episode, max_alts=5):
    titles = [video.series] if episode else [video.title]
    try:
        alts = getattr(
            video,
            "alternative_series" if episode else "alternative_titles",
            None,
        )
        if alts:
            titles.extend(alts)
    except Exception:
        pass
    return _unique_nonempty(titles)[:max_alts]

class SubdivxSubtitle(Subtitle):
    provider_name = "subdivx"
    hash_verifiable = False

    def __init__(
        self,
        language,
        video,
        page_link,
        title,
        description,
        uploader,
        download_url,
    ):
        super(SubdivxSubtitle, self).__init__(
            language,
            hearing_impaired=False,
            page_link=page_link,
        )
        self.video = video
        self.download_url = download_url
        self.uploader = uploader
        self.release_info = str(title).strip()
        if description:
            self.release_info += f" | {description}"

    @property
    def id(self):
        return self.page_link

    def get_matches(self, video):
        matches = set()
        if isinstance(video, Episode):
            matches.update({"title", "series", "season", "episode", "year"})
        elif isinstance(video, Movie):
            matches.update({"title", "year"})
        update_matches(matches, video, self.release_info)
        return matches

# ---------------------------
# Provider
# ---------------------------

class SubdivxSubtitlesProvider(Provider):
    provider_name = "subx"
    hash_verifiable = False
    languages = {
        Language.fromalpha2("es"),
        Language("spa", "MX"),
    }
    video_types = (Episode, Movie)
    subtitle_class = SubdivxSubtitle

    def __init__(self, api_key: str = 'KKMhVa8S_KKMhVa8STCRLKd-SC7FJQCdjg3Tr9Ui0O6eUXPBvjpo'):
        if not api_key:
            raise ProviderError("SubX API key is required")
        self.session = Session()
        self.session.headers.update({
            "Authorization": f"Bearer {api_key}",
        })

    def initialize(self):
        pass

    def terminate(self):
        self.session.close()

    def run_query(self, query, video, video_type):
        params = {
            "query": query,
            "limit": 100,
            "video_type": video_type,
        }
        if video.year:
            params["year"] = video.year

        logger.debug("SubX search params: %s", params)

        try:
            response = self.session.get(
                f"{_SUBX_BASE_URL}/api/subtitles/search",
                params=params,
                timeout=30,
            )
            response.raise_for_status()
            data = response.json()
        except Exception as e:
            logger.error("SubX API error: %s", e)
            return []

        logger.debug(
            "SubX API response: total=%s | items=%d",
            data.get("total"),
            len(data.get("items", [])),
        )

        subtitles = []
        for item in data.get("items", []):
            page_url = item.get("page_url")
            if not page_url and item.get("id"):
                page_url = f"{_SUBX_BASE_URL}/api/subtitles/{item['id']}"

            subtitles.append(self.subtitle_class(
                language=Language.fromalpha2("es"),
                video=video,
                page_link=page_url,
                title=item.get("title"),
                description=item.get("description", ""),
                uploader=item.get("uploader", "unknown"),
                download_url=f"{_SUBX_BASE_URL}/api/subtitles/{item['id']}/download",
            ))

        return subtitles

    def list_subtitles(self, video, languages):
        subtitles = []
        seen_queries = set()

        def query_once(q, vtype):
            if not q or q in seen_queries:
                return []
            seen_queries.add(q)
            res = self.run_query(q, video, vtype)
            time.sleep(5)
            return res or []

        if isinstance(video, Episode):
            titles = _collect_titles(video, episode=True, max_alts=5)
            logger.debug("Titles to look at: %s", titles)
            for raw_title in titles:
                title = _series_sanitizer(raw_title)
                subtitles += query_once(
                    f"{title} S{video.season:02}E{video.episode:02}",
                    "episode",
                )
                subtitles += query_once(
                    f"{title} S{video.season:02}",
                    "episode",
                )
                if len(subtitles) <= 5:
                    subtitles += query_once(title, "episode")
                else:
                    break

            if not subtitles and getattr(video, "title", None) and video.title != title:
                subtitles += query_once(video.title, "episode")

        else:
            titles = _collect_titles(video, episode=False, max_alts=5)
            logger.debug("Titles to look at: %s", titles)
            for t in titles:
                res = query_once(t, "movie")
                if res:
                    subtitles += res
                    break
                if getattr(video, "year", None):
                    res2 = query_once(f"{t} ({video.year})", "movie")
                    if res2:
                        subtitles += res2
                        break

        return subtitles

    def download_subtitle(self, subtitle):
        try:
            response = self.session.get(
                subtitle.download_url,
                timeout=30,
            )
            response.raise_for_status()
        except Exception as e:
            logger.error("Failed to download subtitle: %s", e)
            raise APIThrottled("Failed to download subtitle")

        archive = get_archive_from_bytes(response.content)
        if archive is None:
            raise APIThrottled("Unknown or unsupported archive format")

        episode = (
            subtitle.video.episode
            if isinstance(subtitle.video, Episode)
            else None
        )

        subtitle.content = get_subtitle_from_archive(
            archive,
            episode=episode,
        )
