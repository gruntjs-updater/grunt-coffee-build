# grunt-coffee-build
# https://github.com/tarruda/grunt-coffee-build
#
# Copyright (c) 2013 Thiago de Arruda
# Licensed under the MIT license.

fs = require 'fs'
path = require 'path'

{compile} = require 'coffee-script'
{SourceMapConsumer, SourceMapGenerator} = require 'source-map'
UglifyJS = require 'uglify-js'

NAME = 'coffee_build'
DESC =
  'Compiles Coffeescript files, optionally merging and generating source maps.'


# Cache of compiledfiles, keeps track of the last modified date
# so we can avoid processing it again.
# Useful when this task is used in conjunction with grunt-contib-watch
# in large coffeescript projects
buildCache = {file: {}, dir:{}}


mtime = (fp) -> fs.statSync(fp).mtime.getTime()


buildToDirectory = (grunt, options, f) ->
  cwd = f.orig.cwd or '.'
  outFile = f.dest
  outDir = path.dirname(outFile)

  if /\.coffee$/.test(outFile)
    outFile = outFile.replace(/\.coffee$/, '.js')

  f.src.forEach (file) ->
    if not grunt.file.exists(file)
      grunt.log.warn('Source file "' + file + '" not found.')
      return
    if /\.js/.test(file)
      # plain js, just copy to the output dir
      grunt.file.copy(file, outFile)
      grunt.log.writeln("Copied #{file} to #{outFile}")
      return
    entry = buildCache.dir[file]
    mt = mtime(file)
    if mt != entry?.mtime or outFile not of entry?.generated
      if mt != entry?.mtime
        src = grunt.file.read(file)
        compiled = compile(src, {
          sourceMap: options.sourceMap
          bare: not options.wrap
        })
        grunt.log.writeln("Compiled #{file}")
        if options.sourceMap
          {js: compiled, v3SourceMap} = compiled
          v3SourceMap = JSON.parse(v3SourceMap)
          v3SourceMap.sourceRoot = path.relative(outDir, cwd)
          v3SourceMap.file = path.basename(outFile)
          v3SourceMap.sources[0] = path.relative(cwd, file)
          v3SourceMap = JSON.stringify(v3SourceMap)
          compiled += "\n\n//@ sourceMappingURL=#{path.basename(outFile)}.map"
          grunt.file.write("#{outFile}.map", v3SourceMap)
          grunt.log.writeln("File #{outFile}.map was created")
        buildCache.dir[file] =
          mtime: mt
          compiled: compiled
          map: v3SourceMap
          generated: {}
      grunt.file.write(outFile, compiled)
      grunt.log.writeln("File #{outFile} was created")
      buildCache.dir[file].generated[outFile] = null


# Function adapted from the helper function with same name  thein traceur
# compiler source code.
#
# It generates an ugly identifier for a given pathname relative to
# the current file being processed, taking into consideration a base dir. eg:
# > generateNameForUrl('./b/c') # if the filename is 'a'
# '$$__a_b_c'
# > generateNameForUrl('../d') # if the filename is 'a/b/c'
# '$$__a_b_d'
#
# This assumes you won't name your variables using this prefix
generateNameForUrl = (grunt, url, from, cwd = '.', prefix = '$__') ->
  try
    cwd = path.resolve(cwd)
    from = path.resolve(path.dirname(from))
    url = path.resolve(path.join(from, url))
    if grunt.file.isDir(url)
      # its possible to require directories that have an index.coffee file
      url = path.join(url, 'index')
    ext = /\.(coffee|js)$/
    if ext.test(url)
      url = url.replace(ext, '')
  catch e
    grunt.log.warn(e)
    return null
  id = "$#{prefix + url.replace(cwd, '').replace(/[^\d\w$]/g, '_')}"
  return {id: id, url: path.relative(cwd, url)}


# Replace all the require calls by the generated identifier that represents
# the corresponding module. This will also fill the 'deps' array so the 
# main routine can concatenate the files in proper order
replaceRequires = (grunt, js, fn, fp, cwd, deps) ->
  displayNode = (node) -> js.slice(node.start.pos, node.end.endpos)
  transformer = new UglifyJS.TreeTransformer (node, descend) ->
    if (not (node instanceof UglifyJS.AST_Call) or
        node.expression.name != 'require' or
        (node.args.length != 1 or
         not /^\.(?:\.)?\//.test(node.args[0].value) and
         grunt.log.warn(
           "Cannot process '#{displayNode(node)}' in file #{fn}")) or
        not (mod = generateNameForUrl(grunt, node.args[0].value, fp, cwd)))
      return
    # I couldn't get Uglify to generate a correct mapping from the input
    # map generated by coffeescript, so returning an identifier node
    # to transform the tree wasn't an option.
    #
    # The best solution I found was to use the position information to
    # replace using string slice
    start = node.start.pos - posOffset
    end = node.end.endpos - posOffset
    posOffset += end - start - mod.id.length
    before = js.slice(0, start)
    after = js.slice(end)
    js = before + mod.id + after
    url = mod.url + '.coffee'
    if not grunt.file.exists(path.join(cwd, url))
      url = mod.url + '.js'
    deps.push(url)
    return

  posOffset = 0
  ast = UglifyJS.parse(js)
  ast.transform(transformer)
  return js

# Wraps the compiled coffeescript file into a module that simulates
# a commonjs environment
makeModule = (grunt, js, v3SourceMap, fn, fp, cwd, deps) ->
  moduleName = generateNameForUrl(grunt, fn, '.', '.')
  {id, url} = moduleName
  gen = new SourceMapGenerator({
    file: fn
    sourceRoot: 'tmp'
  })
  if v3SourceMap
    # the module wrapper will push the source 2 lines down
    orig = new SourceMapConsumer(v3SourceMap)
    orig.eachMapping (m) ->
      mapping =
        source: fn
        generated:
            line: m.generatedLine + 2
            column: m.generatedColumn
        original:
          line: m.originalLine or m.generatedLine
          column: m.originalColumn or m.generatedColumn
      gen.addMapping(mapping)
    v3SourceMap = gen.toString()
  js =
    """
    var #{id} = {};
    #{id} = (function(module, exports) {
      #{js}
      return module.exports;
    })({exports: #{id}}, #{id});
    """
  return {js: replaceRequires(grunt, js, fn, fp, cwd, deps), v3SourceMap: v3SourceMap}


# This will create an 1-1 source map that will be used to map a section of the
# bundle to the original javascript file
generateJsSourceMap = (js) ->
  gen = new SourceMapGenerator({
    file: 'tmp'
    sourceRoot: 'tmp'
  })
  for i in [1...js.split('\n').length]
    gen.addMapping
      generated:
        line: i
        column: 0
  return gen.toString()



# Builds all input files into a single js file, parsing 'require' calls
# to resolve dependencies and concatenate in the proper order
buildToFile = (grunt, options, f) ->
  cwd = f.cwd or '.'
  pending = {}
  processed = {}
  bundle = []
  outFile = f.dest
  outDir = path.dirname(outFile)

  files = f.src.filter (file) ->
    file = path.join(cwd, file)
    if not grunt.file.exists(file)
      grunt.log.warn('Source file "' + file + '" not found.')
      return false
    return true

  gen = new SourceMapGenerator({
    file: path.basename(outFile)
    sourceRoot: path.relative(outDir, cwd)
  })
  output = ''
  lineOffset = 0
  if options.wrap
    lineOffset = 1

  while files.length
    fn = files.shift()
    fp = path.join(cwd, fn)
    if fp of processed
      continue
    if (mt = mtime(fp)) != buildCache.file[fp]?.mtime
      deps = []
      if (/\.coffee$/.test(fp))
        {js, v3SourceMap} = compile(grunt.file.read(fp), {
          sourceMap: true, bare: true})
      else # plain js
        js = grunt.file.read(fp)
        v3SourceMap = null
        if not options.disableSourceMap or fn not in options.disableSourceMap
          v3SourceMap = generateJsSourceMap(js)
      if not options.disableModuleWrap or fn not in options.disableModuleWrap
        {js, v3SourceMap} = makeModule(
          grunt, js, v3SourceMap, fn, fp, cwd, deps)
      else
        js = replaceRequires(grunt, js, fn, fp, cwd, deps)
      cacheEntry = buildCache.file[fp] =
        {js: js, mtime: mt, v3SourceMap: v3SourceMap, deps: deps, fn: fn}
      if /\.coffee$/.test(fp)
        grunt.log.writeln("Compiled #{fp}")
      else
        grunt.log.writeln("Transformed #{fp}")
    else
      # Use the entry from cache
      {deps, js, v3SourceMap, fn} = cacheEntry = buildCache.file[fp]
    if deps.length
      depsProcessed = true
      for dep in deps
        if dep not of processed
          depsProcessed = false
          break
      if not depsProcessed and fp not of pending
        pending[fp] = null
        files.unshift(fn)
        for dep in deps when dep not of pending
          files.unshift(dep)
        continue
    # flag the file as processed
    processed[fp] = null
    if v3SourceMap
      # concatenate the file output, and update the result source map with
      # the input source map information
      orig = new SourceMapConsumer(v3SourceMap)
      orig.eachMapping (m) ->
        gen.addMapping
          generated:
              line: m.generatedLine + lineOffset
              column: m.generatedColumn
          original:
              line: m.originalLine or m.generatedLine
              column: m.originalColumn or m.generatedColumn
          source: fn
    lineOffset += js.split('\n').length - 1
    output += js
  if options.wrap
    output = '(function(self) {\n' + output + '\n}).call({}, this);'
  if options.sourceMap
    sourceMapDest = path.basename(outFile) + '.map'
    output += "\n\n//@ sourceMappingURL=#{sourceMapDest}"
    grunt.file.write("#{outFile}.map", gen.toString())
    grunt.log.writeln("File #{outFile}.map was created")
  grunt.file.write(outFile, output)
  grunt.log.writeln("File #{outFile} was created")


module.exports = (grunt) ->
  grunt.registerMultiTask NAME, DESC, ->
    options = this.options(sourceMap: true, wrap: true)

    @files.forEach (f) ->
      if /\.js$/.test(f.orig.dest)
        buildToFile(grunt, options, f)
      else
        buildToDirectory(grunt, options, f)
