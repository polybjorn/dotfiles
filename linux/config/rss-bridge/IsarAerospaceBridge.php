<?php

class IsarAerospaceBridge extends BridgeAbstract
{
    const NAME = 'Isar Aerospace';
    const URI = 'https://www.isaraerospace.com';
    const DESCRIPTION = 'Press releases from Isar Aerospace';
    const MAINTAINER = 'polybjorn';
    const CACHE_TIMEOUT = 43200; // 12 hours

    public function collectData()
    {
        $url = 'https://isaraerospace.com/news-press-releases';
        $dom = getSimpleHTMLDOM($url);
        if (!$dom) {
            throw new \Exception('Could not load newsroom page');
        }

        foreach ($dom->find('div.teaser-grid a') as $a) {
            $title = $a->find('h3', 0);
            if (!$title) {
                continue;
            }

            $href = $a->href;
            if (strpos($href, '/press/') === false) {
                continue;
            }
            if (strpos($href, 'http') !== 0) {
                $href = self::URI . $href;
            }

            $item = [];
            $item['uri'] = $href;
            $item['title'] = trim($title->plaintext);

            $dateDiv = $a->find('div.tag', 0);
            if ($dateDiv) {
                $item['timestamp'] = strtotime(trim($dateDiv->plaintext));
            }

            $articleDom = getSimpleHTMLDOMCached($href, self::CACHE_TIMEOUT);
            if ($articleDom) {
                $content = '';
                foreach ($articleDom->find('p') as $p) {
                    $text = trim($p->plaintext);
                    if ($text && strpos($text, '@isaraerospace.com') === false) {
                        $content .= '<p>' . $p->innertext . '</p>';
                    }
                }
                $item['content'] = $content;
            }

            $this->items[] = $item;
        }
    }
}
