export const POCKET_CSV = `title,url,time_added,tags,status
"Hello, World",https://example.com/a?utm_source=x,1700000000,tech|rust,unread
"Multi
line ""quoted"" title",https://example.com/b,1600000000,"one,two",archive
No tags,https://example.com/c,1650000000,,unread
Bad url,javascript:alert(1),1650000000,,unread
,not a url,,,
Ünïcode,https://example.com/ü,0,Żółw|żółw,archive
`;

export const POCKET_HTML = `<!DOCTYPE html>
<html><head><meta charset="UTF-8"><title>Pocket Export</title></head>
<body>
<h1>Unread</h1>
<ul>
<li><a href="https://example.com/u1" time_added="1700000100" tags="news,tech">First &amp; best</a></li>
<li><a href="https://example.com/u2" time_added="1700000200" tags="">Second</a></li>
</ul>
<h1>Read Archive</h1>
<ul>
<li><a href="https://example.com/r1" time_added="1500000000" tags="old">Archived one</a></li>
<li><a href="ftp://example.com/x" time_added="1500000001" tags="">Bad scheme</a></li>
</ul>
</body></html>`;

export const INSTAPAPER_CSV = `URL,Title,Selection,Folder,Timestamp,Tags
https://example.com/i1,Unread one,,Unread,1700000000,"[""a"",""b""]"
https://example.com/i2,Archived one,"some selection",Archive,1690000000,[]
https://example.com/i3,Starred one,,Starred,1680000000,
https://example.com/i4,Custom folder,,Recipes,1670000000,
https://example.com/i5,No timestamp,,Unread,,
`;

export const INSTAPAPER_CSV_OLD = `URL,Title,Selection,Folder,Timestamp
https://example.com/old,Old format,,Unread,1700000000
`;

export const NETSCAPE_HTML = `<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3 ADD_DATE="1700000000">Folder A</H3>
    <DL><p>
        <DT><A HREF="https://example.com/n1" ADD_DATE="1700000500" TAGS="x,y z">Netscape one</A>
        <DD>A description
        <DT><A HREF="https://example.com/n2" ADD_DATE="1700000600">Netscape two</A>
    </DL><p>
    <DT><A HREF="place:sort=8&amp;maxResults=10" ADD_DATE="1700000700">Recent</A>
    <DT><A HREF='https://example.com/n3?a=1&amp;b=2' ADD_DATE='1700000800' ICON="data:image/png;base64,AAAA">Single quoted</A>
</DL><p>
`;
