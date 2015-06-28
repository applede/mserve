require "selenium-webdriver"
require "open-uri"

class Movie
  attr_accessor :image_url, :studio, :year, :director, :summary, :full_title, :title, :actors,
                :runtime, :genre, :mpaa
end

CD_REGEX = /\s*-\s*cd(\d)\.[^.]+$/i
RED = "\x1b[31m"
RESET = "\x1b[0m"

class Scraper
  def print_line(*args)
    args.each do |arg|
      print arg
    end
    puts RESET
  end

  def nfo_file(path)
    if CD_REGEX =~ path
      return path.sub(CD_REGEX, '.nfo')
    end
    return path.sub(/\.[^.]+$/, '.nfo')
  end

  def video_file(path)
    return /\.(mkv|mov|mp4|avi|wmv|iso)$/ =~ path
  end

  def primary_file(path)
    if CD_REGEX =~ path
      return $1 == '1'
    end
    return true
  end

  def need_nfo(path)
    if File.exist?(path) && video_file(path) && primary_file(path)
      nfo = nfo_file(path)
      if File.exist?(nfo)
        nfo_time = File.new(nfo).mtime
        file_time = File.new(path).mtime
        return nfo_time < file_time
      else
        return true
      end
    else
      return false
    end
  end

  def url_exist?(url)
    begin
      open(url)
      return true
    rescue
      return false
    end
  end

  def escape(str)
    str.gsub('<', '&lt;')
       .gsub('>', '&gt;')
       .gsub(/&(?!amp;)/, '&amp;')
  end

  def dash_part(path, i)
    name = File.basename(path, '.*')
    name.split(' - ')[i]
  end

  def cleanup_actor(actor)
    return actor.sub(/^and /, '')
                .sub(/^with /, '')
                .strip()
  end

  def find_entry(i)
    entries = @browser.find_elements(css: "a.media-list-inner-item.show-actions")
    if i >= entries.count
      i = i % entries.count
    end
    entries[i].location_once_scrolled_into_view()
    # @browser.execute_script('arguments[0].scrollIntoView(true);', entries[i]);
    return entries[i]
  end

  def wait(selector)
    if selector.start_with?('/')
      @wait.until { @browser.find_element(xpath: selector)}
    else
      @wait.until { @browser.find_element(css: selector)}
    end
  end

  def try_find(selector)
    begin
      if selector.start_with?('/')
        return @browser.find_element(xpath: selector)
      else
        return @browser.find_element(css: selector)
      end
    rescue
      return nil
    end
  end

  def find_element(*selectors)
    selector1, selector2 = *selectors
    elem = try_find(selector1)
    return elem if elem
    elem = try_find(selector2)
    return elem if elem
    return nil
  end

  def find_elements(*selectors)
    selector1, selector2 = *selectors
    if selector1.start_with?('/')
      elements = @browser.find_elements(xpath: selector1)
    else
      elements = @browser.find_elements(css: selector1)
    end
    if elements.length == 0 && selector2
      if selector2.start_with?('/')
        elements = @browser.find_elements(xpath: selector2)
      else
        elements = @browser.find_elements(css: selector2)
      end
    end
    return elements
  end

  def find_text(*selectors)
    selector1, selector2 = *selectors
    text = find_element(selector1).text
    if text == ''
      text = find_element(selector2).text
    end
    return text
  end

  def click(selector)
    if selector.start_with?('/')
      @browser.find_element(xpath: selector).click
    else
      @browser.find_element(css: selector).click
    end
  end

  def click_child(entry, css)
    entry.find_element(css: css).click
  end

  def send_keys(selector, str)
    if selector.start_with?('/')
      elem = @browser.find_element(xpath: selector)
    else
      elem = @browser.find_element(css: selector)
    end
    elem.click
    elem.clear
    elem.send_keys(str, :enter)
  end

  def send_os_keys(*args)
    if args.last == :enter
      enter_str = 'keystroke return'
    else
      enter_str = ''
    end
    if args[0] == :command
      key_str = "key down {command}\nkeystroke \"#{args[1]}\"\nkey up {command}\n"
    else
      key_str = "keystroke \"#{args[0]}\"\n"
    end
    system('osascript', '-e', "tell application \"System Events\"\n#{key_str}#{enter_str}\nend tell")
  end

  def find_filename(entry)
    @browser.action.move_to(entry).perform
    click_child(entry, 'button.more-btn')
    click('div.media-actions-dropdown > ul.dropdown-menu > li > a.info-btn')
    sleep(1)
    filename = find_element('div.files > ul.media-info-file-list.well > li').text
    click('div.modal-header > button.close')
    sleep(1)
    return filename
  end

  def switch_window()
    sleep(1) # wait new tab open
    windows = @browser.window_handles()
    windows.each do |win|
      if !@windows.include?(win)
        @windows.push(win)
        @browser.switch_to().window(win)
        break
      end
    end
    sleep(1) # wait new tab load
  end

  def open_tab()
    @browser.execute_script('window.open()')
    switch_window()
  end

  def close_tab()
    @browser.close()
    @windows.pop()
    @browser.switch_to().window(@windows.last)
  end

  def close_tabs()
    while @windows.length > 1
      close_tab()
    end
  end

  def close_tab_by_key()
    send_os_keys(:command, 'w')
    @windows.pop()
    @browser.switch_to().window(@windows.last)
  end

  def send_enter(str)
    find_element('#lst-ib').send_keys(str, :enter)
  end

  def search(words)
    open_tab()
    @browser.get('https://google.com')
    send_enter(words)
    sleep(2)
  end

  def search_term(path)
    term = dash_part(path, -1)
    return term.gsub(/\s*\(1080p\)\s*$/, '')
               .sub(/\s*\(\d\d\d\d\)$/, '')
  end

  def alt_terms(term)
    return [
      term,
      term.gsub(/\btwo\b/i, '2'),
      term.gsub(/\bpart 1\b/i, 'part i'),
      term.gsub(/\band\b/i, '&')
    ]
  end

  def alt_texts(text)
    return [text, text.gsub(/\.\.\./, ' ')]
  end

  def include_one_of?(texts, terms)
    terms.each do |term|
      texts.each do |text|
        if text.downcase.include?(term.downcase)
          return true
        end
      end
    end
    return false
  end

  def does_match(text, path)
    %r{([^/]+)\/([^/]+)\.[^.]+$} =~ path
    file = $2
    folder = $1
    name = file.gsub(/_/, ' ')
               .sub(/ and /i, ' & ')
               .sub(/^the /i, '')
    parts = name.split(' - ')
    if parts.length > 1
      name = parts[1]
    else
      name = parts[0]
    end
    return text.downcase.include?(name.downcase)
  end

  def extra_name(path)
    %r{([^/]+)\/([^/]+)\.[^.]+$} =~ path
    file = $2
    folder = $1
    name = file.gsub(/_/, ' ')
               .sub(/ - ntsc$/i, '')
               .sub(/ ntsc$/i, '')
    parts = name.split(' - ')
    if parts.length > 2
      return ' - ' + parts[2..-1].join(' - ')
    end
    return ''
  end

  def title_from(path)
    search_term(path).split(' ').map {|w| w.capitalize}.join(' ')
  end

  def normalize(filename)
    return File.basename(filename, '.*')
      .sub('X-art', 'X-Art')
  end

  def wait_until_file_exist(path)
    count = 20
    while count > 0 && !File.exist?(path)
      sleep(1)
      count -= 1
    end
    if count == 0
      print_line(RED, "Can't download #{path}")
      exit
    end
  end

  def download_image(css)
    sleep(1)
    image = find_element(css)
    @browser.action.move_to(image).context_click().perform
    send_os_keys('s', :enter)
    system('rm', "-f", "#{Dir.home}/Downloads/temp.jpg")
    sleep(3)
    send_os_keys('temp', :enter)

    path = "#{Dir.home}/Downloads/temp.jpg"
    wait_until_file_exist(path)
    return path
  end

  def download_image_new_tab(url)
    open_tab()
    @browser.get(url)
    return download_image('img')
  end

  def download_image_auto(url)
    open_tab()
    last_part = url.split('/')[-1]
    filename = last_part.split('?')[0].gsub(' ', '_').gsub('\'', '')
    path = "#{Dir.home}/Downloads/#{filename}"
    if File.exist?(path)
      File.delete(path)
    end
    @browser.get(url)
    wait_until_file_exist(path)
    close_tab_by_key()
    return path
  end

  def priority_by_length(text)
    return 99 - text.length
  end

  def candidates_from_google(s_term, site)
    search("#{s_term} site:#{site}")

    candi = []

    find_elements('#rso li > div > h3 > a').each do |elem|
      if include_one_of?(alt_texts(elem.text), alt_terms(s_term))
        # reject some words
        if elem.text.sub(/x-art\s*/i, '').downcase != s_term.downcase && s_term.downcase == 'sunset'
          next
        end
        # more score for first one
        score = 100 - candi.length
        # more score for short one (more important than first one)
        score += 100 - elem.text.length * 2
        # more score for gallery
        link = elem.find_element(xpath: '../../div/div/div/cite')
        href = link.text
        if href
          if href.include?('/galleries/')
            score += 5
          end
          # avoid beta and hosted
          if /^beta/ =~ href || /^hosted/ =~ href || /^dev/ =~ href || /^branch/ =~ href
            next
          end
        end
        candi.push([elem, score])
      end
    end

    return candi
  end

  def candidates_from_adultfilmdatabase(path)
    candi = []

    open_tab()
    @browser.get('http://www.adultfilmdatabase.com/director.cfm?directorid=165')

    find_elements('/html/body/table[3]/tbody/tr/td[1]/table/tbody/tr[5]/td/table/tbody/tr[1]/td/table/tbody/tr/td[1]/span/a').each do |elem|
      if does_match(elem.text, path)
        candi.push([elem, 100 + priority_by_length(elem.text)])
      end
    end

    return candi
  end

  def scrape_internal(path, candidates)
    candidates.sort! { |a, b| b[1] <=> a[1] }
    candidates[0][0].click

    switch_window()

    movie = Movie.new
    yield movie

    image = path.sub(/\.[^.]+$/, '-poster.jpg')
    open(image, 'wb') do |local_file|
      open(movie.image_url, 'rb') do |remote_file|
        local_file.write(remote_file.read)
      end
    end
    if movie.image_url.start_with?('/')
      File.delete(movie.image_url)
    end

    actors = ''
    movie.actors.each do |actor|
      actors += <<-END_ACTOR
  <actor>
    <name>#{actor}</name>
  </actor>
END_ACTOR
    end
    nfo = path.sub(/\.[^.]+$/, '.nfo')
    open(nfo, 'w') do |file|
      file.puts <<-END_NFO
<movie>
  <title>#{escape(movie.title)}</title>
  <year>#{movie.year}</year>
  <plot>#{escape(movie.summary)}</plot>
  <runtime>#{movie.runtime}</runtime>
  <director>#{movie.director}</director>
  <genre>#{movie.genre}</genre>
  <studio>#{movie.studio}</studio>
  <mpaa>#{movie.mpaa}</mpaa>
#{actors}
</movie>
END_NFO
    end

    return true
  end

  def scrape_andrew_blake(path)
    candi = candidates_from_adultfilmdatabase()
    if candi.empty?
      candi = candidates_from_google(search_term(path), 'store.andrewblake.com')
      scrape_internal(path, candidates) do |movie|
        image = find_element('#product_thumbnail')
        movie.image_url = image.attribute('src')
        if /\b\d\d\d\d\b/ =~ path
          movie.year = $&
        end
        movie.studio = ''
        movie.title = find_element('//*[@id="center-main"]/h1').text.sub(/ DVD$/, '') + extra_name(path)
        movie.genre = ''
        movie.mpaa = 'X'
        find_elements('//*[@id="center-main"]/div[2]/div/div/div[2]/form/table[1]/tbody/tr/td/p').each do |elem|
          if !movie.summary
            movie.summary = elem.text
          end
          if elem.text.start_with?('Starring: ')
            movie.actors = elem.text[10..-1].split(', ')
          end
          if elem.text.start_with?('Directed')
            movie.director = elem.text.split(' by ')[-1]
          end
          if /(\d+) minute feature film/i =~ elem.text
            movie.runtime = $1
          end
        end
      end
    else
      scrape_internal(path, candidates) do |movie|
        extra = extra_name(path)
        if extra != ''
          image = find_element('/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[1]/table/tbody/tr[2]/td/a/img',
                               '/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[1]/table/tbody/tr[1]/td/img')
        else
          image = find_element('body > table:nth-child(7) > tbody > tr > td > table:nth-child(1) > tbody > tr > td:nth-child(1) > table > tbody > tr:nth-child(1) > td > img',
                               'body > table:nth-child(7) > tbody > tr > td > table:nth-child(1) > tbody > tr > td:nth-child(1) > table > tbody > tr:nth-child(1) > td > a > img')
        end
        movie.image_url = image.attribute('src')
        hi_src = movie.image_url.sub('200', '350')
        if url_exist?(hi_src)
          movie.image_url = hi_src
        end

        movie.studio = find_element('body > table:nth-child(7) > tbody > tr > td > table:nth-child(1) > tbody > tr > td:nth-child(2) > table:nth-child(9) > tbody > tr:nth-child(2) > td:nth-child(2) > u > a',
                                    '/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[2]/table[2]/tbody/tr[2]/td[2]/u/a').text
        movie.year = find_element('body > table:nth-child(7) > tbody > tr > td > table:nth-child(1) > tbody > tr > td:nth-child(2) > table:nth-child(9) > tbody > tr:nth-child(3) > td:nth-child(2)',
                                  '/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[2]/table[2]/tbody/tr[3]/td[2]').text
        movie.director = find_element('body > table:nth-child(7) > tbody > tr > td > table:nth-child(1) > tbody > tr > td:nth-child(2) > table:nth-child(9) > tbody > tr:nth-child(4) > td:nth-child(2) > a',
                                      '/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[2]/table[2]/tbody/tr[4]/td[2]/a').text
        movie.summary = find_element('body > table:nth-child(7) > tbody > tr > td > table:nth-child(1) > tbody > tr > td:nth-child(2) > table:nth-child(9) > tbody > tr:nth-child(6) > td',
                                     '/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[2]/table[2]/tbody/tr[6]/td').text
        movie.title = find_element('/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[2]/span').text + extra
        movie.actors = find_elements('/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[2]/table[1]/tbody/tr/td/div/span/a/u').map { |elem| elem.text }
        movie.runtime = find_element('/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[2]/table[2]/tbody/tr[1]/td[2]').text
        movie.genre = find_element('/html/body/table[3]/tbody/tr/td/table[1]/tbody/tr/td[2]/table[2]/tbody/tr[5]/td[2]').text
        movie.mpaa = 'X'
      end
    end
  end

  def scrape_james_deen(path)
    scrape_internal(path, 'james deen', 'jamesdeenproductions.com') do |movie|
      image = find_element('img.attachment-product-image.wp-post-image')

      movie.image_url = image.attribute('src')
      movie.studio = 'James Deen Productions'
      movie.year = nil
      movie.director = nil
      movie.summary = find_element('/html/body/div[1]/div/main/section/div/div/div[1]/p[2]').text
      movie.full_title = 'James Deen - ' + title_from(path)
    end
  end

  def scrape_x_art(path)
    candi = candidates_from_google(search_term(path), 'x-art.com')
    if candi.empty?
      print_line(RED, " ⇨ can't find")
      return
    end
    scrape_internal(path, candi) do |movie|
      movie.title = find_element('#content > h1').text
      movie.studio = 'X-Art'
      if find_element('//*[@id="content"]/ul/li[1]').text =~ /.+(\d\d\d\d)/
        movie.year = $1
      end
      movie.actors = find_elements('//*[@id="content"]/ul/li[2]/a').map { |elem| elem.text }
      movie.mpaa = 'X'

      if find_element('img.gallery-cover')
        movie.image_url = download_image('img.gallery-cover')

        movie.summary = find_text('//*[@id="content"]/div[1]/div[2]/div/p',
                                  '//*[@id="content"]/div[1]/div[2]/div/p[2]')
      else
        image_url = find_element('//*[@id="tab1"]/div/div[1]/table[1]/tbody/tr/td/table/tbody/tr[1]/td').attribute('background')
        movie.image_url = download_image_auto(image_url)

        movie.summary = find_text('//*[@id="tab1"]/div/div[2]/p',
                                  '//*[@id="tab1"]/div/div[2]/p[2]')
      end
    end
  end

  def scrape_wowgirls(path)
    
  end

  def scrape_joy_mii(path)
    scrape_internal(path, 'joymii', 'joymii.com/site/set-video') do |movie|
      sleep(1)
      image = find_element('div.video-container > div.video-js', '#video-placeholder > img.poster')
      url = image.attribute('poster')
      if !url
        url = image.attribute('src')
      end
      download_image_new_tab(url)
      movie.image_url = "file://#{Dir.home}/Downloads/temp.jpg"
      movie.studio = 'JoyMii'
      movie.summary = find_element('div.info > p.text').text
      title = find_element('h1.title').text
      actors = find_elements('h2.starring-models > a').map { |elem| elem.text }.join(', ')
      movie.full_title = "JoyMii - #{actors} - #{title}"
    end
  end

  def scrape_newsensations(path)
    candi = candidates_from_google(dash_part(path, -1), 'newsensations.com')
    scrape_internal(path, candi) do |movie|
      movie.title = find_element('//*[@id="container"]/table/tbody/tr/td/table/tbody/tr[2]/td/form/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr[2]/td/table/tbody/tr/td/table/tbody/tr/td[3]/div/table/tbody/tr/td/div/h1').text
      text = find_element('//*[@id="container"]/table/tbody/tr/td/table/tbody/tr[2]/td/form/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr[2]/td/table/tbody/tr/td/table/tbody/tr/td[3]/div/table/tbody/tr/td/div/div[2]/table/tbody/tr[1]/td').text
      texts = text.split('Starring: ')
      movie.summary = texts[0]

      actors = texts[1].split('Street Date:')[0]
      movie.actors = actors.split(', ').map { |actor| cleanup_actor(actor)}
      date = find_element('//*[@id="container"]/table/tbody/tr/td/table/tbody/tr[2]/td/form/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr[2]/td/table/tbody/tr/td/table/tbody/tr/td[3]/div/table/tbody/tr/td/div/div[2]/table/tbody/tr[1]/td/table/tbody/tr[1]/td/table/tbody/tr[1]/td[2]').text
      /\d\d-\d\d-(\d\d\d\d)/ =~ date
      movie.year = $1
      movie.studio = find_element('//*[@id="container"]/table/tbody/tr/td/table/tbody/tr[2]/td/form/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr/td/table/tbody/tr[2]/td/table/tbody/tr/td/table/tbody/tr/td[3]/div/table/tbody/tr/td/div/span/a').text
      movie.mpaa = 'X'

      movie.image_url = download_image('#productinfo_bigimage')
    end
    exit
  end

  def scrape_file(path)
    if path =~ /andrew blake|andrew_blake/i
      scrape_andrew_blake(path)
    elsif path =~ /\/x-art/i
      scrape_x_art(path)
    elsif path =~ /\/wowgirls/i
      scrape_wowgirls(path)
    elsif path =~ /james deen/i
      scrape_james_deen(path)
    elsif path =~ /joymii/i
      scrape_joy_mii(path)
    elsif path =~ /newsensations/i
      scrape_newsensations(path)
    else
      print_line(RED, " ⇨ ignored")
    end
  end

  def traverse(folder, &block)
    Dir.entries(folder).each do |file|
      unless file.start_with?('.')
        path = File.join(folder, file)
        if File.directory?(path)
          traverse(path, &block)
        else
          if need_nfo(path)
            puts(path)
            block.call(nfo_file(path))
          end
        end
      end
    end
  end

  def scrape
    @browser = Selenium::WebDriver.for :chrome, :switches => %w[--user-data-dir=./Chrome]
    @wait = Selenium::WebDriver::Wait.new(:timeout => 5)
    sleep(1)
    @windows = @browser.window_handles()

    traverse('/Users/apple/mount/public/porn') do |path|
      scrape_file(path)
      close_tabs()
    end
  end
end

scraper = Scraper.new
scraper.scrape
